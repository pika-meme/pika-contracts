// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { PikaAppBase } from "./PikaAppBase.sol";
import { IPikaHolderBook, IPikaAppToken, IPikaAppFactory, IPikaAppRegistry } from "./interfaces/IPikaApps.sol";

/// @notice "持有者分红": the dividend sink. Project fees are shared among the launch's plain holders by balance and
///         time held, in the launch token (buy fees) and its quote asset (sell fees); holders claim themselves, anyone
///         may claim for them. A launch may set a minimum holding ("分红资格最低持仓"): a holder below it has no shares.
/// @dev The launch token reports every balance change (`setShares`: both parties and their balances) and nothing
///      else; every rule about who earns is here, where it can be upgraded (user decision 2026-11-03). A holder's
///      shares are its balance, except: the launch's platform accounts (the zero and burn addresses, the vault, the
///      launch's components and app slots, which the token names in `isPlatformAccount`) hold none; holders below
///      the launch's minimum holding hold none until their balance reaches it again; and the accounts the registry's
///      owner (the timelock) lists per launch (`setExcluded`, for third-party pools and other contracts whose balance
///      belongs to their users, following Flap's `excludeAddress`) hold none. The token no longer probes contracts
///      for pool-like interfaces. Excluding an account settles what it earned: a plain wallet is paid it at once, a
///      contract's share goes back to the launch's unreleased fees for the other holders (version 12; a pool cannot
///      claim, so paying it would strand or leak the money); a list entry cannot be a platform account, and the owner
///      may remove it again, which rereads the account's balance. Token transfers require their share update to
///      succeed. `refresh` rereads a holder's balance and applies the same rules, so a record can always be made to
///      agree with them.
///
///      Fees are released per second (staking-rewards style), not shared at the moment they are booked. Fees reach
///      this sink in batches (`PikaToken.pushFees`, which anyone may run), so sharing each batch at once would let
///      whoever holds at that moment take fees earned while others held: buy, push, claim, sell (audit 2026-10-29b
///      L-1). Instead each booking adds its amount to what is still unreleased in that asset and restarts the release
///      over `RELEASE_WINDOW` from now; what is released is spread over the shares held at that time, as a running
///      "reward per share" (scaled by 2^128). A holder earns for exactly the seconds it holds, so a buy just before
///      a push earns only the seconds' worth it stays. While nobody holds shares the release waits: the window moves
///      on by the time nobody held. Rounding stays unreleased and goes out later. A holder's owed amount is settled
///      whenever its shares change and when it claims. Releasing is constant work and runs inside transfers.
contract PikaDividendApp is PikaAppBase, IPikaHolderBook {
    bytes32 public constant KEY = "dividend";
    uint16 public constant VERSION = 12;
    /// @notice The highest minimum holding a launch may set, as a share of its supply: 10%. The spread of ordinary
    ///         holdings puts a threshold near the supply out of everyone's reach, and fees sent to a book nobody can
    ///         join are stuck (audit 2026-10-31 M-3). Applies to launches created after this version; earlier
    ///         bindings keep theirs.
    uint256 public constant MAX_MIN_HOLDING_BPS = 1000;
    /// @notice Claim at most this many holders per `claimFor` call.
    uint256 public constant MAX_CLAIM_HOLDERS = 100;
    /// @notice A booking's fees, with what is still unreleased in that asset, are released evenly over this window.
    ///         It is longer than the keeper's push interval, so a known push cannot be sniped by a short hold.
    uint256 public constant RELEASE_WINDOW = 1 days;
    uint256 private constant SCALE = 2 ** 128;
    address private constant BURN = 0x000000000000000000000000000000000000dEaD;

    /// @dev Per launch and asset: the reward per share released so far, what is booked and not yet released, the
    ///      last release and when the current window ends. Keep the packed layout for existing proxies; bookings
    ///      check the combined unreleased amount before narrowing instead of silently truncating extreme inputs.
    struct Book {
        uint256 perShare;
        uint128 unreleased;
        uint64 updatedAt;
        uint64 endsAt;
    }

    /// @dev Per launch, asset and holder: the reward per share it was settled at and what it is owed since. Both stay
    ///      full words: the reward per share grows without a useful bound when few shares exist.
    struct Account {
        uint256 paidPerShare;
        uint256 owed;
    }

    /// @dev Per launch, fixed at registration: the quote asset and the minimum holding in whole tokens, in one slot
    ///      every share update reads. A nonzero quote also proves registration.
    struct Launch {
        address quote;
        uint96 minHoldingTokens;
    }

    mapping(address token => uint256) public totalShares;
    /// @notice The shares the token last reported for a holder: its balance, or zero below the launch's minimum.
    mapping(address token => mapping(address holder => uint256)) public shares;
    mapping(address token => mapping(address asset => Book)) public books;
    mapping(address token => mapping(address asset => mapping(address holder => Account))) public accounts;
    /// @dev Before version 11: the minimum holding in the token's smallest unit and the lazily cached quote. Kept in
    ///      place for proxies upgraded from version 10; their launches move to `launches` on first use.
    mapping(address token => uint256) private legacyMinHolding;
    mapping(address token => address quote) private legacyQuote;
    /// @notice The owner-managed exclusion list, per launch: accounts that hold no shares besides the launch's
    ///         platform accounts (`isExcluded` covers both). Appended in template version 9.
    mapping(address token => mapping(address account => bool)) public excluded;
    /// @dev Appended in template version 11.
    mapping(address token => Launch) private launches;

    error TooManyHolders();

    /// @dev `amount` is in the launch token, `quoteAmount` in its quote asset.
    event DividendClaimed(address indexed token, address indexed holder, uint256 amount, uint256 quoteAmount);
    /// @notice The owner added `account` to (or removed it from) the launch's exclusion list. On an exclusion,
    ///         `amount` of the launch token and `quoteAmount` of quote it had earned went back to the unreleased fees;
    ///         both are zero for a wallet, which is paid its earnings instead (`DividendClaimed`).
    event AccountExcluded(
        address indexed token, address indexed account, bool excluded, uint256 amount, uint256 quoteAmount
    );

    constructor(address registry_) PikaAppBase(registry_) { }

    function templateKey() external pure returns (bytes32) {
        return KEY;
    }

    function version() external pure virtual returns (uint16) {
        return VERSION;
    }

    /// @dev Parameters: `abi.encode(uint256 minHolding)` in whole tokens, 0 to `MAX_MIN_HOLDING_BPS` of the launch
    ///      supply; 0 means no minimum. Always exactly one word: the creator chooses the minimum, so an empty binding
    ///      is refused. The token is not initialized when it binds (its `totalSupply()` is still zero), so the supply
    ///      is read from its factory, which fixes every launch's supply to `defaultSupply` in the same call.
    ///      The token set its quote before it registers, so both are stored here at once.
    function _register(address token, bytes calldata params) internal override {
        if (params.length != 32) revert InvalidParams();
        uint256 supply = IPikaAppFactory(IPikaAppToken(token).factory()).defaultSupply();
        uint256 count = abi.decode(params, (uint256));
        _wholeTokens(count, 0, supply * MAX_MIN_HOLDING_BPS / 10_000 / UNIT);
        address quote = _quote(token);
        if (quote == address(0)) revert InvalidParams();
        launches[token] = Launch(quote, SafeCast.toUint96(count));
    }

    // ---------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------

    /// @notice What a holder can claim right now, released up to this second: launch token and quote asset.
    function pending(address token, address holder) external view returns (uint256 amount, uint256 quoteAmount) {
        uint256 s = shares[token][holder];
        uint256 supply = totalShares[token];
        amount = _due(token, token, holder, s, supply);
        quoteAmount = _due(token, _quote(token), holder, s, supply);
    }

    /// @notice What is booked in `asset` and not yet released as of this second, and the release per second from
    ///         now on (zero while nobody holds shares: the release waits).
    function unreleased(address token, address asset) external view returns (uint256 amount, uint256 perSecond) {
        Book storage b = books[token][asset];
        uint256 supply = totalShares[token];
        (, amount) = _released(b, supply);
        if (amount == 0 || supply == 0 || block.timestamp >= b.endsAt) return (amount, 0);
        perSecond = amount / (b.endsAt - block.timestamp);
    }

    /// @notice The smallest balance, in the token's smallest unit, that earns dividends; zero means every plain holder.
    function minHolding(address token) public view returns (uint256) {
        Launch memory l = launches[token];
        return l.quote != address(0) ? uint256(l.minHoldingTokens) * UNIT : legacyMinHolding[token];
    }

    /// @notice Whether `account` holds no shares of `token` by rule: a platform account of the launch (excluded by
    ///         default) or an entry of the owner's list.
    function isExcluded(address token, address account) external view returns (bool) {
        return excluded[token][account] || _platform(token, account);
    }

    /// @notice The shares `holder` should have right now by the rules: its balance, or zero when excluded or below
    ///         the launch's minimum holding. `shares` is what the book recorded; `refresh` makes them agree.
    function expectedShares(address token, address holder) external view returns (uint256) {
        return _reported(token, holder);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Booking and release
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Releases what is due up to now, then adds `amount` to the unreleased rest and restarts the window.
    function _book(address token, address asset, uint256 amount) internal override {
        Book storage b = books[token][asset];
        _release(b, totalShares[token]);
        // A rejected booking reverts the token's whole push, including its payment and cleared fee snapshot.
        b.unreleased = SafeCast.toUint128(uint256(b.unreleased) + amount);
        b.updatedAt = uint64(block.timestamp);
        b.endsAt = uint64(block.timestamp + RELEASE_WINDOW);
    }

    /// @dev Moves what is due since the last release into the reward per share of `supply`. Runs before any share
    ///      change, with the supply before it.
    function _release(Book storage b, uint256 supply) private {
        if (b.unreleased == 0 || b.updatedAt == block.timestamp) return;
        if (supply == 0) {
            // Nobody earns: the window waits for the time nobody held.
            // forge-lint: disable-next-line(unsafe-typecast)
            b.endsAt = uint64(b.endsAt + block.timestamp - b.updatedAt);
        } else {
            (uint256 perShare, uint256 rest) = _released(b, supply);
            b.perShare = perShare;
            // forge-lint: disable-next-line(unsafe-typecast)
            b.unreleased = uint128(rest);
        }
        b.updatedAt = uint64(block.timestamp);
    }

    /// @dev The reward per share and the unreleased rest after releasing what is due up to now over `supply`.
    ///      Holders are entitled to `delta * supply / SCALE`, a fraction in general; rounding it up for the rest keeps
    ///      the book solvent, and the dust goes out with a later release.
    function _released(Book storage b, uint256 supply) private view returns (uint256 perShare, uint256 rest) {
        perShare = b.perShare;
        rest = b.unreleased;
        uint256 last = b.updatedAt;
        if (rest == 0 || last == block.timestamp || supply == 0) return (perShare, rest);
        uint256 ends = b.endsAt;
        uint256 due = block.timestamp >= ends ? rest : rest * (block.timestamp - last) / (ends - last);
        uint256 delta = Math.mulDiv(due, SCALE, supply);
        perShare += delta;
        rest -= Math.mulDiv(delta, supply, SCALE, Math.Rounding.Ceil);
    }

    function _releaseBoth(address token, address quote) private {
        uint256 supply = totalShares[token];
        _release(books[token][token], supply);
        _release(books[token][quote], supply);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Shares
    // ---------------------------------------------------------------------------------------------------------

    /// @inheritdoc IPikaHolderBook
    function setShares(address from, uint256 fromBalance, address to, uint256 toBalance) external {
        address token = msg.sender;
        (address quote, uint256 min) = _launch(token);
        (uint256 fromShares, bool fromChanges) = _next(token, from, fromBalance, min);
        (uint256 toShares, bool toChanges) = _next(token, to, toBalance, min);
        if (!fromChanges && !toChanges) return;
        _releaseBoth(token, quote);
        // Release against the old supply and settle both holders before changing the total. Ordinary transfers
        // between eligible holders leave it unchanged and need no total-supply write.
        uint256 beforeTotal = totalShares[token];
        uint256 total = beforeTotal;
        if (fromChanges) total = total + fromShares - _settleHolder(token, quote, from, fromShares);
        if (toChanges) total = total + toShares - _settleHolder(token, quote, to, toShares);
        if (total != beforeTotal) totalShares[token] = total;
    }

    /// @dev One party's shares after a transfer and whether they differ from the recorded ones.
    function _next(address token, address account, uint256 balance, uint256 min)
        private
        view
        returns (uint256 next, bool changes)
    {
        uint256 old = shares[token][account];
        next = _effective(token, account, balance, min, old);
        changes = next != old;
    }

    /// @notice Reread a holder's balance from the launch token and record the shares the rules give it. Anyone may
    ///         call it; every transfer already does this for both parties.
    function refresh(address token, address holder) external {
        (address quote,) = _launch(token);
        uint256 s = _reported(token, holder);
        if (shares[token][holder] == s) return;
        _releaseBoth(token, quote);
        _set(token, quote, holder, s);
    }

    /// @dev The shares every rule gives `holder` for its balance right now.
    function _reported(address token, address holder) private view returns (uint256) {
        return _effective(token, holder, IPikaAppToken(token).balanceOf(holder), minHolding(token), 0);
    }

    /// @dev The shares a balance is worth: nothing for an empty or too small balance; otherwise the balance, except
    ///      for this sink, the burn address, a listed account or one of the launch's platform accounts (one read of
    ///      the token, skipped when the cheaper checks already answer). A holder that already has shares (`recorded`)
    ///      passed those identity checks when it got them and still does: the token fixes its platform accounts
    ///      before the supply exists and has the book `refresh` the one it adds later (the order manager), and
    ///      listing an account zeroes its shares at once. So a holder's balance changes skip them, which is most of
    ///      the work of an ordinary transfer.
    function _effective(address token, address account, uint256 balance, uint256 min, uint256 recorded)
        private
        view
        returns (uint256)
    {
        if (balance == 0 || balance < min) return 0;
        if (recorded != 0) return balance;
        if (account == address(this) || account == BURN || excluded[token][account]) return 0;
        if (_platform(token, account)) return 0;
        return balance;
    }

    /// @dev Asks the token whether `account` is one of its platform accounts.
    function _platform(address token, address account) private view returns (bool) {
        return IPikaAppToken(token).isPlatformAccount(account);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Exclusion list
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Add `account` to, or remove it from, the launch's exclusion list. Only the registry's owner (the
    ///         timelock). Platform accounts are excluded by rule and cannot be listed. Excluding zeroes the account's
    ///         shares and settles what it earned so far in both assets: an account without code (a wallet) is paid it
    ///         at once, like a claim (`DividendClaimed`), since the list only stops its future earnings; a contract's
    ///         earnings return to the launch's unreleased fees (released over `RELEASE_WINDOW` like a booking, so the
    ///         moment cannot be sniped), since a pool cannot claim and whatever is sent to it is lost to its users or
    ///         skimmed (audit 2026-11-07, U-2). Removing an entry rereads the account's balance, so it earns again
    ///         from now on.
    function setExcluded(address token, address account, bool excluded_) external nonReentrant {
        if (msg.sender != IPikaAppRegistry(registry).owner()) revert Unauthorized();
        (address quote,) = _launch(token);
        if (excluded[token][account] == excluded_ || _platform(token, account)) revert InvalidParams();
        excluded[token][account] = excluded_;
        _releaseBoth(token, quote);
        uint256 amount;
        uint256 quoteAmount;
        if (excluded_) {
            _set(token, quote, account, 0);
            if (account.code.length == 0) {
                _claim(token, quote, account, account);
            } else {
                Account storage m = accounts[token][token][account];
                Account storage q = accounts[token][quote][account];
                (amount, quoteAmount) = (m.owed, q.owed);
                m.owed = 0;
                q.owed = 0;
                if (amount != 0) _book(token, token, amount);
                if (quoteAmount != 0) _book(token, quote, quoteAmount);
            }
        } else {
            _set(token, quote, account, _reported(token, account));
        }
        emit AccountExcluded(token, account, excluded_, amount, quoteAmount);
    }

    /// @dev Settles what the old shares earned in both assets, then records the new shares. Releases ran before.
    function _set(address token, address quote, address holder, uint256 newShares) private {
        uint256 old = _settleHolder(token, quote, holder, newShares);
        totalShares[token] = totalShares[token] + newShares - old;
    }

    function _settleHolder(address token, address quote, address holder, uint256 newShares)
        private
        returns (uint256 old)
    {
        old = shares[token][holder];
        _settle(token, token, holder, old);
        _settle(token, quote, holder, old);
        shares[token][holder] = newShares;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Pay the caller what it is owed by the launch, in both assets, to `recipient`.
    /// @dev Never gated by the registry's pause: what a holder has earned is its own, and the guardian's emergency
    ///      stop (`setAppPaused`) only stops the entries that trade (the burn and liquidity sinks' dispatches). A
    ///      user decision of 2026-11-03.
    function claim(address token, address recipient)
        external
        nonReentrant
        returns (uint256 amount, uint256 quoteAmount)
    {
        if (recipient == address(0) || recipient == address(this)) revert InvalidParams();
        (address quote,) = _launch(token);
        _releaseBoth(token, quote);
        return _claim(token, quote, msg.sender, recipient);
    }

    /// @notice Pay up to `MAX_CLAIM_HOLDERS` holders what they are owed, each to itself. Anyone may call it and pays
    ///         the gas. Holders with code are skipped and claim through `claim`. Not gated by the pause either.
    function claimFor(address token, address[] calldata holders_) external nonReentrant {
        if (holders_.length > MAX_CLAIM_HOLDERS) revert TooManyHolders();
        (address quote,) = _launch(token);
        _releaseBoth(token, quote);
        // Contracts claim for themselves: a pool not yet on the exclusion list holds shares, and paying it would let
        // anyone skim its dividends (audit 2026-11-02, L-3).
        for (uint256 i; i < holders_.length; ++i) {
            if (holders_[i].code.length != 0) continue;
            _claim(token, quote, holders_[i], holders_[i]);
        }
    }

    /// @dev Releases ran before.
    function _claim(address token, address quote, address holder, address recipient)
        private
        returns (uint256 amount, uint256 quoteAmount)
    {
        uint256 s = shares[token][holder];
        _settle(token, token, holder, s);
        _settle(token, quote, holder, s);
        amount = accounts[token][token][holder].owed;
        quoteAmount = accounts[token][quote][holder].owed;
        if (amount == 0 && quoteAmount == 0) return (0, 0);
        accounts[token][token][holder].owed = 0;
        accounts[token][quote][holder].owed = 0;
        emit DividendClaimed(token, holder, amount, quoteAmount);
        _send(token, recipient, amount);
        _send(quote, recipient, quoteAmount);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Credits what `s` shares earned since the last settlement. Share updates do not need the total owed:
    ///      read it only to add an actual reward or pay a claim. Before the first release (including all curve
    ///      trades), the monotonic accumulator is zero and no account can have earned anything in this asset.
    function _settle(address token, address asset, address holder, uint256 s) private {
        uint256 perShare = books[token][asset].perShare;
        if (perShare == 0) return;
        Account storage a = accounts[token][asset][holder];
        uint256 paid = a.paidPerShare;
        if (perShare == paid) return;
        if (s != 0) {
            uint256 earned = Math.mulDiv(perShare - paid, s, SCALE);
            if (earned != 0) a.owed += earned;
        }
        a.paidPerShare = perShare;
    }

    /// @dev What the holder is owed in `asset` right now, counting what would be released up to this second.
    function _due(address token, address asset, address holder, uint256 s, uint256 supply)
        private
        view
        returns (uint256 owed)
    {
        Account storage a = accounts[token][asset][holder];
        (uint256 perShare,) = _released(books[token][asset], supply);
        owed = a.owed;
        uint256 paid = a.paidPerShare;
        if (s != 0 && perShare > paid) owed += Math.mulDiv(perShare - paid, s, SCALE);
    }

    /// @dev The launch's quote and minimum holding (in the token's smallest unit); reverts for an unregistered
    ///      token. A launch registered before version 11 is moved into `launches` here, once.
    function _launch(address token) private returns (address quote, uint256 min) {
        Launch storage l = launches[token];
        quote = l.quote;
        if (quote != address(0)) return (quote, uint256(l.minHoldingTokens) * UNIT);
        if (!registered[token]) revert UnknownLaunch();
        quote = legacyQuote[token];
        if (quote == address(0)) quote = _quote(token);
        min = legacyMinHolding[token];
        launches[token] = Launch(quote, SafeCast.toUint96(min / UNIT));
    }
}
