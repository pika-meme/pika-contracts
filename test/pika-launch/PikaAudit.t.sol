// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { OpenFourTypes } from "../../src/openfour/libraries/OpenFourTypes.sol";
import { MockOpenFourCore } from "../helpers/MockOpenFourCore.sol";

/// @dev A creator wallet that can, at will, start answering ERC165 queries like an Infinity-vault settlement
///      contract. Off by default; since 2026-11-03 the token probes nothing, so what it answers never matters.
contract AuditToggleCreator {
    bool public armed;

    function setArmed(bool value) external {
        armed = value;
    }

    function create(MockOpenFourCore core, OpenFourTypes.CreateTokenArgs calldata args)
        external
        payable
        returns (address)
    {
        return core.createToken{ value: msg.value }(args);
    }

    receive() external payable { }

    fallback() external payable {
        if (!armed) revert("disarmed");
        uint256 word;
        if (msg.sig == bytes4(keccak256("supportsInterface(bytes4)"))) {
            bytes4 id = abi.decode(msg.data[4:], (bytes4));
            word = id == bytes4(0xb2e69f8a) ? 1 : 0;
        }
        assembly {
            mstore(0, word)
            return(0, 32)
        }
    }
}

/// @notice Audit regressions on the local Infinity stack.
contract PikaAuditTest is PikaInfinityFixture {
    function testContractCreatorCannotBlockNativeGraduation() public {
        _assertCreatorCannotBlockGraduation(address(0), true);
    }

    function testContractCreatorCannotBlockNativeGraduationReversedPair() public {
        _assertCreatorCannotBlockGraduation(address(0), false);
    }

    function testContractCreatorCannotBlockStableGraduation() public {
        _assertCreatorCannotBlockGraduation(address(usdt), true);
    }

    function testContractCreatorCannotBlockStableGraduationReversedPair() public {
        _assertCreatorCannotBlockGraduation(address(usdt), false);
    }

    /// @dev A1 regression: changing creator behaviour cannot veto funded graduation or redirect project fees.
    function _assertCreatorCannotBlockGraduation(address quote, bool baseIs0) private {
        AuditToggleCreator evil = new AuditToggleCreator();
        LaunchParams memory p;
        p.name = "Audit";
        p.symbol = "AUD";
        p.quoteToken = quote;
        address quoteAsset = quote == address(0) ? address(wbnb) : quote;
        p.creatorFeeRecipient = CREATOR;
        p.target = quote == address(0) ? 18 ether : 12_000 ether;
        p.buyFeeBps = 100;
        p.sellFeeBps = 200;
        do {
            p.salt = bytes32(++salt);
        } while ((_predict(address(evil), p) < quoteAsset) != baseIs0);
        PikaToken token = PikaToken(evil.create(core, _createArgs(p)));
        assertEq(factory.coreRecord(address(token)).creator, address(evil));
        assertEq(token.creatorFeeRecipient(), CREATOR);
        assertEq(token.memeIsCurrency0(), baseIs0);

        // Change creator behaviour before the crossing buy: graduation happens inside that buy.
        uint256 creatorBefore = _walletTotal(token, address(token), CREATOR);
        assertEq(token.balanceOf(address(evil)), 0);
        evil.setArmed(true);
        _fill(token, quote);
        uint128 liquidity = _poolLiquidity(token);
        assertGt(liquidity, 0);
        assertEq(uint256(_info(address(token)).phase), uint256(PikaLaunchFactory.Phase.External));
        assertTrue(token.tradingStarted());
        assertTrue(evil.armed());
        assertEq(_walletTotal(token, address(token), CREATOR), creatorBefore);
        assertEq(token.balanceOf(address(factory)), 0);
        uint128 locked = locker.positions(address(token));
        uint256 excess = token.balanceOf(address(locker));
        assertEq(locked, liquidity);
        assertEq(_poolLiquidity(token), liquidity);
        assertEq(token.balanceOf(address(locker)), excess);

        _assertFeesReachTheRecipient(token, quote, quoteAsset, evil, liquidity, creatorBefore);

        // The successful migration does not reopen the curve; the creator receives ordinary transfers.
        vm.prank(ALICE);
        vm.expectRevert(MockOpenFourCore.BadPhase.selector);
        core.sell(address(token), 1 ether, 0, 0, "");
        vm.prank(ALICE);
        token.transfer(address(evil), 1 ether);
        assertEq(token.balanceOf(address(evil)), 1 ether);
    }

    /// @dev The trading half of the A1 regression, split out (twice) to stay within the legacy pipeline's stack.
    function _assertFeesReachTheRecipient(
        PikaToken token,
        address quote,
        address quoteAsset,
        AuditToggleCreator evil,
        uint128 liquidity,
        uint256 creatorBefore
    ) private {
        _assertSellFeeReachesTheRecipient(token, quoteAsset, evil, creatorBefore);
        _assertBuyFeeReachesTheRecipient(token, quote, evil);
        assertEq(_poolLiquidity(token), liquidity);
    }

    /// @dev A normal trader can sell externally, with the project fee (in quote) going to the independent fee
    ///      recipient.
    function _assertSellFeeReachesTheRecipient(
        PikaToken token,
        address quoteAsset,
        AuditToggleCreator evil,
        uint256 creatorBefore
    ) private {
        uint256 quoteVaultBefore = IERC20(quoteAsset).balanceOf(address(vault));
        uint256 creatorQuoteBefore = _walletTotal(token, quoteAsset, CREATOR);
        (uint256 spent, uint256 output) = _swap(token, ALICE, true, 1_000_000 ether);
        assertEq(spent, 1_000_000 ether);
        assertGt(output, 0);
        // The hook's fee is split by the platform's bps share of the fee itself; rounding goes to the recipient.
        uint256 fee = _tradeFee(token, quoteVaultBefore - IERC20(quoteAsset).balanceOf(address(vault)), false);
        assertEq(_walletTotal(token, quoteAsset, CREATOR) - creatorQuoteBefore, _walletPart(token, fee, false));
        assertEq(_walletTotal(token, address(token), CREATOR), creatorBefore);
        assertEq(token.balanceOf(address(evil)), 0);
        assertEq(IERC20(quoteAsset).balanceOf(address(evil)), 0);
    }

    /// @dev Buying also routes the project fee to the recipient, never to the creator contract.
    function _assertBuyFeeReachesTheRecipient(PikaToken token, address quote, AuditToggleCreator evil) private {
        uint256 creatorBefore = _walletTotal(token, address(token), CREATOR);
        uint256 vaultBefore = _vaultBalance(token);
        if (quote == address(0)) deal(address(wbnb), CAROL, 100 ether);
        _swap(token, CAROL, false, 100 ether);
        uint256 fee = _tradeFee(token, vaultBefore - _vaultBalance(token), true);
        assertEq(_walletTotal(token, address(token), CREATOR) - creatorBefore, _walletPart(token, fee, true));
        assertEq(token.balanceOf(address(evil)), 0);
    }
}
