// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { DeployPikaTestnetScript } from "../../script/DeployPikaTestnet.s.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaRouter } from "../../src/pika-launch/PikaRouter.sol";
import { PikaTradeLens } from "../../src/pika-launch/PikaTradeLens.sol";
import { PikaTokenParams } from "../../src/pika-launch/interfaces/IPikaLaunch.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";
import { OpenFourTypes } from "../../src/openfour/libraries/OpenFourTypes.sol";
import { IOpenFourVault } from "../../src/openfour/interfaces/IOpenFourVault.sol";
import { IOpenFourRegistry } from "../../src/openfour/interfaces/IOpenFourRegistry.sol";
import { OpenFourStandardModules } from "../../script/OpenFourStandardModules.sol";

interface IRealCore {
    function createToken(bytes memory createArgs, bytes memory signature) external payable returns (address token);
    function buyByBudget(address token, uint256 maxPayAmount, uint256 minAmountOut, uint256 options, bytes calldata)
        external
        payable;
    function buy(address token, uint256 amount, uint256 maxPayAmount, uint256 options, bytes calldata)
        external
        payable;
    function sell(address token, uint256 amount, uint256 minReceiveAmount, uint256 options, bytes calldata) external;
    function migrate(address token) external;
    function feeRouter() external view returns (address);
}

interface IRealFeeRouter {
    function devFeePending(address quoteAsset, address author) external view returns (uint256);
}

/// @notice The Pika preset on a BSC-testnet fork of OpenFour's real (closed-source) Core: deploys the Pika stack
///         with `DeployPikaTestnet` onto the developer-owned OpenFour fork, then creates, trades and graduates a launch.
/// @dev Runs only with RUN_PIKA_OPENFOUR_FORK=true, PRIVATE_KEY (the fork's Registry owner and Core signer) and
///      OPENFOUR_REGISTRY. Nothing is broadcast.
contract PikaOpenFourTestnetForkTest is Test {
    address constant CREATOR = address(uint160(uint256(keccak256("pika.fork.creator"))));
    address constant ALICE = address(uint160(uint256(keccak256("pika.fork.alice"))));
    address constant BOB = address(uint160(uint256(keccak256("pika.fork.bob"))));
    address constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    bool enabled;
    uint256 key;
    DeployPikaTestnetScript.Deployment d;
    IRealCore core;
    uint256 nonce;

    function setUp() public {
        enabled = vm.envOr("RUN_PIKA_OPENFOUR_FORK", false);
        if (!enabled) return;
        vm.createSelectFork(vm.envOr("TESTNET_RPC_URL", string("https://bsc-testnet.publicnode.com")));
        key = vm.envUint("PRIVATE_KEY");
        DeployPikaTestnetScript s = new DeployPikaTestnetScript();
        d = s.run();
        core = IRealCore(d.hub.core());
        vm.deal(CREATOR, 10 ether);
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
    }

    function _args(uint256 target, uint256 presale, AppBinding[] memory apps)
        internal
        returns (OpenFourTypes.CreateTokenArgs memory a)
    {
        uint256 supply = d.hub.defaultSupply();
        a.requestId = ++nonce + block.timestamp;
        a.presetId = d.presetId;
        a.validTimestamp = block.timestamp + 1 hours;
        a.presaleQuote = presale;
        a.initParams.name = "Pika Fork";
        a.initParams.symbol = "PFORK";
        a.initParams.tokenUri = "ipfs://pika";
        a.initParams.maxSupply = supply;
        a.initParams.saleAmount = d.hub.sizing(supply, target).saleAmount;
        a.initParams.raiseAmount = target;
        a.initParams.quoteAsset = WBNB;
        a.initParams.tokenSalt = keccak256(abi.encode(nonce, block.timestamp));
        a.initParams.tokenParams = abi.encode(PikaTokenParams(CREATOR, 100, 200, apps));
    }

    function _create(OpenFourTypes.CreateTokenArgs memory a, address caller) internal returns (PikaToken) {
        bytes memory createArgs = abi.encode(a);
        bytes32 digest =
            keccak256(abi.encodePacked("createOpenFourToken", block.chainid, caller, keccak256(createArgs)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(digest));
        vm.prank(caller);
        return PikaToken(core.createToken{ value: a.presaleQuote }(createArgs, abi.encodePacked(r, s, v)));
    }

    function test_FullLifecycleOnRealCore() public {
        if (!enabled) return;
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(1, 5000, 5000, abi.encode(uint256(0))); // the dividend sink
        PikaToken token = _create(_args(0.1 ether, 0, apps), CREATOR);
        (, PikaLaunchFactory.Phase phase,) = d.hub.launches(address(token));
        assertEq(uint8(phase), uint8(PikaLaunchFactory.Phase.Internal));
        OpenFourTypes.RuntimeConfig memory r = d.hub.coreRecord(address(token));
        assertTrue(r.exists);
        assertEq(r.presetId, d.presetId);
        IOpenFourVault v = IOpenFourVault(token.vault());
        assertEq(uint8(v.phase()), uint8(OpenFourTypes.Phase.Trading));
        assertEq(token.balanceOf(address(v)), d.hub.defaultSupply());

        // A budget buy in native BNB, quoted first by the lens (OpenFour Tools).
        vm.prank(ALICE);
        PikaTradeLens.Quote memory q = d.lens.quote(address(token), false, 0.02 ether, 100);
        vm.prank(ALICE);
        core.buyByBudget{ value: 0.02 ether }(address(token), 0.02 ether, 1, 0, "");
        uint256 got = token.balanceOf(ALICE);
        assertGt(got, 0);
        assertApproxEqRel(got, q.output, 1e15);
        emit log_named_uint("curve quote raised", v.totalRaised());
        emit log_named_uint("developer fee to the Pika treasury",
            IRealFeeRouter(core.feeRouter()).devFeePending(WBNB, d.hub.treasury()));

        // A sell back to native BNB.
        uint256 before = ALICE.balance;
        vm.startPrank(ALICE);
        token.approve(address(core), got / 2);
        core.sell(address(token), got / 2, 1, 0, "");
        vm.stopPrank();
        assertGt(ALICE.balance, before);

        // The crossing buy graduates into the Infinity launch pool.
        vm.prank(BOB);
        core.buyByBudget{ value: 0.2 ether }(address(token), 0.2 ether, 1, 0, "");
        assertEq(v.remainingForSale(), 0);
        assertTrue(token.tradingStarted(), "graduated in the crossing buy");
        assertEq(uint8(v.phase()), uint8(OpenFourTypes.Phase.Migrated));
        ICLPoolManager manager = ICLPoolManager(address(token.poolManager()));
        assertGt(manager.getLiquidity(token.poolId()), 0);

        // The launch pool trades through the router, with the hook's fees.
        vm.prank(ALICE);
        (uint256 spent, uint256 out) = PikaRouter(payable(token.tradingRouter()))
            .swap{ value: 0.01 ether }(
                PikaRouter.SwapParams(address(token), false, 0.01 ether, 1, ALICE, block.timestamp, true)
            );
        assertEq(spent, 0.01 ether);
        assertGt(out, 0);
        token.pushFees();
    }

    function test_GraduationPreservesTreasuryDebtInPikaQuote() public {
        if (!enabled) return;
        PikaToken token = _create(_args(0.1 ether, 0, new AppBinding[](0)), CREATOR);
        vm.prank(ALICE);
        core.buyByBudget{ value: 0.02 ether }(address(token), 0.02 ether, 1, 0, "");
        vm.prank(address(d.timelock));
        d.hub.configureQuote(address(token), true, 10 ether);
        OpenFourTypes.CreateTokenArgs memory a = _args(12_000 ether, 0, new AppBinding[](0));
        a.initParams.quoteAsset = address(token);
        PikaToken other = _create(a, CREATOR);
        vm.startPrank(ALICE);
        token.approve(address(core), 24_000 ether);
        core.buyByBudget(address(other), 24_000 ether, 1, 0, "");
        vm.stopPrank();
        assertTrue(other.tradingStarted());
        uint256 owed = d.hub.pendingTreasuryQuote(address(token));
        assertGt(owed, 100 ether);
        assertEq(token.balanceOf(address(d.hub)), owed);

        vm.prank(BOB);
        core.buyByBudget{ value: 0.2 ether }(address(token), 0.2 ether, 1, 0, "");

        assertTrue(token.tradingStarted());
        assertEq(d.hub.pendingTreasuryQuote(address(token)), owed);
        assertEq(token.balanceOf(address(d.hub)), owed);
        address treasury = d.hub.treasury();
        uint256 before = token.balanceOf(treasury);
        assertEq(d.hub.claimTreasuryQuote(address(token)), owed);
        assertEq(token.balanceOf(treasury) - before, owed);
        assertEq(token.balanceOf(address(d.hub)), 0);
    }

    /// @dev Gas of each step on the real Core, for the record (run with `--isolate` so every call is its own
    ///      transaction and starts cold).
    function test_GasOnRealCore() public {
        if (!enabled) return;
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(1, 5000, 5000, abi.encode(uint256(0))); // the dividend sink
        PikaToken token = _create(_args(0.1 ether, 0, apps), CREATOR);
        emit log_named_uint("gas: createToken (dividend app, no first buy)", vm.lastCallGas().gasTotalUsed);
        vm.prank(ALICE);
        core.buyByBudget{ value: 0.02 ether }(address(token), 0.02 ether, 1, 0, "");
        emit log_named_uint("gas: buyByBudget (new holder)", vm.lastCallGas().gasTotalUsed);
        vm.prank(BOB);
        core.buy{ value: 0.02 ether }(address(token), 1_000_000 ether, 0.02 ether, 0, "");
        emit log_named_uint("gas: buy by amount (new holder)", vm.lastCallGas().gasTotalUsed);
        vm.prank(BOB);
        core.buy{ value: 0.02 ether }(address(token), 1_000_000 ether, 0.02 ether, 0, "");
        emit log_named_uint("gas: buy by amount (existing holder)", vm.lastCallGas().gasTotalUsed);
        uint256 half = token.balanceOf(ALICE) / 2;
        vm.prank(ALICE);
        token.approve(address(core), half);
        vm.prank(ALICE);
        core.sell(address(token), half, 1, 0, "");
        emit log_named_uint("gas: sell", vm.lastCallGas().gasTotalUsed);
        vm.prank(BOB);
        core.buyByBudget{ value: 0.2 ether }(address(token), 0.2 ether, 1, 0, "");
        emit log_named_uint("gas: buyByBudget that graduates", vm.lastCallGas().gasTotalUsed);
        assertTrue(token.tradingStarted());
        PikaToken plain = _create(_args(0.1 ether, 0, new AppBinding[](0)), CREATOR);
        emit log_named_uint("gas: createToken (no apps)", vm.lastCallGas().gasTotalUsed);
        vm.prank(ALICE);
        core.buy{ value: 0.02 ether }(address(plain), 1_000_000 ether, 0.02 ether, 0, "");
        emit log_named_uint("gas: buy by amount, no apps (new holder)", vm.lastCallGas().gasTotalUsed);
    }

    /// @dev The vault slot is OpenFour's standard vault, whose Registry record names its author (OpenFour) with a
    ///      `feeShareBps` of 1500. The real FeeRouter still credits the whole developer fee to the preset's author, the
    ///      Pika treasury, and nothing to the vault's author (BSC testnet fork, 2026-11-05).
    function test_DeveloperFeeWithTheStandardVault() public {
        if (!enabled) return;
        IOpenFourRegistry.ModuleRecord memory m =
            IOpenFourRegistry(vm.envAddress("OPENFOUR_REGISTRY")).getModule(OpenFourStandardModules.VAULT_KEY);
        address author = m.metadata.author;
        emit log_named_address("standard vault author", author);
        emit log_named_uint("standard vault feeShareBps", m.metadata.feeShareBps);
        PikaToken token = _create(_args(0.1 ether, 0, new AppBinding[](0)), CREATOR);
        IRealFeeRouter fr = IRealFeeRouter(core.feeRouter());
        address treasury = d.hub.treasury();
        uint256 treasuryBefore = fr.devFeePending(WBNB, treasury);
        uint256 authorBefore = fr.devFeePending(WBNB, author);
        vm.recordLogs();
        vm.prank(ALICE);
        core.buyByBudget{ value: 0.02 ether }(address(token), 0.02 ether, 1, 0, "");
        uint256 devFee = _tradeDevFee();
        uint256 toTreasury = fr.devFeePending(WBNB, treasury) - treasuryBefore;
        uint256 toAuthor = fr.devFeePending(WBNB, author) - authorBefore;
        emit log_named_uint("trade devFee", devFee);
        emit log_named_uint("developer fee to the Pika treasury", toTreasury);
        emit log_named_uint("developer fee to the vault author", toAuthor);
        assertGt(devFee, 0);
        assertEq(toTreasury, devFee, "the whole developer fee goes to the Pika treasury");
        assertEq(toAuthor, 0, "none to the standard vault's author");
    }

    /// @dev The `devFee` of the last recorded `TradeExecuted`.
    function _tradeDevFee() internal returns (uint256 fee) {
        bytes32 topic = keccak256(
            "TradeExecuted(address,address,uint256,bool,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            // Non-indexed words: isBuy, quoteAsset, vault, requested, amount, curveQuote, traderQuote, lastPrice,
            // slippageLimit, protocolFee, taxFee, devFee, ...
            (,,,,,,,,,,, fee) = abi.decode(
                logs[i].data,
                (
                    bool, address, address, uint256, uint256, uint256,
                    uint256, uint256, uint256, uint256, uint256, uint256
                )
            );
        }
    }

    /// @dev No purchase limit (removed 2026-11-06): with OpenFour's simple trade policy in the trade slot and no
    ///      custom data module, the real Core lets one buyer take any share of the sale, directly or through a
    ///      contract (a wallet's or aggregator's router), and the router's buys do not cap each other.
    function test_NoPurchaseLimitOnRealCore() public {
        if (!enabled) return;
        uint256 supply = d.hub.defaultSupply();
        PikaToken token = _create(_args(0.1 ether, 0.01 ether, new AppBinding[](0)), CREATOR);
        assertGt(token.balanceOf(CREATOR), supply / 100);
        assertEq(token.customData(), address(0));
        vm.prank(ALICE);
        core.buyByBudget{ value: 0.02 ether }(address(token), 0.02 ether, 1, 0, "");
        assertGt(token.balanceOf(ALICE), supply / 20);
        vm.prank(ALICE);
        core.buy{ value: 0.02 ether }(address(token), supply / 20, 0.02 ether, 0, "");
        ForkBuyRouter router = new ForkBuyRouter(address(core));
        vm.prank(BOB);
        router.buyFor{ value: 0.01 ether }(address(token), BOB);
        vm.prank(CREATOR);
        router.buyFor{ value: 0.01 ether }(address(token), CREATOR);
        assertGt(token.balanceOf(BOB), supply / 100);
        assertFalse(token.tradingStarted());
    }

    function test_CreatorFirstBuyCanGraduateAtCreation() public {
        if (!enabled) return;
        PikaToken token = _create(_args(0.1 ether, 0.2 ether, new AppBinding[](0)), CREATOR);
        assertTrue(token.tradingStarted());
    }

    function test_BadSignatureAndBadParametersAreRefused() public {
        if (!enabled) return;
        OpenFourTypes.CreateTokenArgs memory a = _args(0.1 ether, 0, new AppBinding[](0));
        bytes memory createArgs = abi.encode(a);
        vm.prank(CREATOR);
        vm.expectRevert();
        core.createToken(createArgs, new bytes(65));
        a.initParams.saleAmount -= 1;
        vm.expectRevert();
        _create(a, CREATOR);
    }

    /// @dev How Core derives a token's address from `tokenSalt`: logs the candidates (discovery, 2026-11-05).
    function test_TokenAddressFromSalt() public {
        if (!enabled) return;
        OpenFourTypes.CreateTokenArgs memory a = _args(0.1 ether, 0, new AppBinding[](0));
        bytes32 salt = a.initParams.tokenSalt;
        PikaToken token = _create(a, CREATOR);
        address impl = d.modules.tokenImpl;
        address dep = 0x71A31d460920B0A8c0218Ce35Ca55FdAAFCCDa40;
        address c = address(core);
        address[6] memory cands = [
            Clones.predictDeterministicAddress(impl, salt, dep),
            Clones.predictDeterministicAddress(impl, keccak256(abi.encode(CREATOR, salt)), dep),
            Clones.predictDeterministicAddress(impl, keccak256(abi.encodePacked(CREATOR, salt)), dep),
            Clones.predictDeterministicAddress(impl, salt, c),
            Clones.predictDeterministicAddress(impl, keccak256(abi.encode(CREATOR, salt)), c),
            Clones.predictDeterministicAddress(impl, keccak256(abi.encodePacked(CREATOR, salt)), c)
        ];
        emit log_named_address("token", address(token));
        for (uint256 i; i < cands.length; ++i) emit log_named_address("candidate", cands[i]);
    }
}

/// @dev A minimal router: buys on Core with the caller's budget and hands the tokens on, as a wallet's or aggregator's
///      router would. Core credits the buy to the router.
contract ForkBuyRouter {
    IRealCore immutable core;

    constructor(address core_) {
        core = IRealCore(core_);
    }

    function buyFor(address token, address to) external payable {
        core.buyByBudget{ value: msg.value }(token, msg.value, 1, 0, "");
        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
    }

    receive() external payable { }
}
