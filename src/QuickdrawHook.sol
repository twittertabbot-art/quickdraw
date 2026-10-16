// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {QuickdrawGame} from "./QuickdrawGame.sol";
import {QuickdrawNFT} from "./QuickdrawNFT.sol";
import {QuickdrawRenderer} from "./QuickdrawRenderer.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// The token, as the hook sees it: balances to read, and the two raw moves only the game may make.
interface IQuickdrawToken {
    function balanceOf(address who) external view returns (uint256);
    function gameMove(address from, address to, uint256 amount) external;
    function gameBurn(address from, uint256 amount) external;
}

/*//////////////////////////////////////////////////////////////////////////
        QUICKDRAW // the game: the street, and the v4 hook of the DRAW pool
//////////////////////////////////////////////////////////////////////////*/
/*
  Two hats, one address: the street (balance-as-mass: a wallet's DRAW balance is its hand on the street) and the
  Uniswap v4 hook of the one native ETH / DRAW pool. The token is a separate contract (QuickdrawToken) that asks
  this hook before every transfer (the two launch caps) and tells it afterwards (the resync), and that lets only
  this hook move or burn balances raw (draws, decay). Only a hook can reach the ETH side of the pool's swaps at
  swap time, and that is what lets winners earn native ETH and lets the street draw on itself. No keeper is
  required, no server, no cron; trade flow is the engine (a keeper may poke resolveEats() to land draws on time).

  FEE MATHS. Every swap pays its fee in ETH, on the ETH leg, in all four shapes, and the token side is never
  touched. bps = DEV_TAX_BPS + BOUNTY_FEE_BPS + PLATFORM_BPS = 430 (4.3%):
    buy, exact input  (ETH named):   fee = named * bps / 10000, taken in beforeSwap off the named amount
    sell, exact output (ETH named):  the pool pays named + fee, fee = named * bps / (10000 - bps), beforeSwap
    buy, exact output (DRAW named):  the pool takes net ETH, the swapper pays net + fee, fee = net * bps / 10000
    sell, exact input (DRAW named):  the pool pays gross ETH, the swapper gets gross - fee, fee = gross * bps / 10000
  Split, always, with no switch and no setter: 2.5% to the treasury (the dev wallet, pushed in the same tx),
  1.5% into the standing bounty, 0.30% to Programmable (PLATFORM_RECIPIENT, accrued in platformOwed, paid by
  claimPlatform()). The same call arms a volume-paced draw that resolves a block later off a sealed seed.

  ETH custody, asserted relentlessly: this contract holds ONLY fees it has not yet paid out, never holder mass:
      address(this).balance >= bloodReserve() + platformOwed + treasuryEthOwed
      bloodReserve() == ethIn - ethOut + escrow
  The pool's liquidity belongs to the launcher (a position with no removal function); this hook adds none.
*/
contract QuickdrawHook is QuickdrawGame, IHooks {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // Permit2, the canonical universal approval conduit, same address on every chain (9,152 bytes on chain 1).
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // Ethereum mainnet infrastructure that may hold or route DRAW without ever being a hand on the street.
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;   // Uniswap, v4-aware
    address internal constant UNIVERSAL_ROUTER_2 = 0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA; // older, still used by front ends
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;   // Uniswap v4 PositionManager
    address internal constant PROGRAMMABLE_ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C; // Programmable's trading router
    address internal constant GRAPH_FACTORY = 0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887;       // Programmable's Graph Factory
    address internal constant ROUTER_24H = 0xBE4bF6Ac8c6F012E1C8f25747A9fBccB2FDAC4C3;          // Programmable's 24h Router
    bytes4 internal constant MSG_SENDER_SELECTOR = 0xd737d0c7; // msgSender(): the wallet a trusted router acts for
    // transient slot carrying a swap's authenticated buyer from beforeSwap to afterSwap (keccak256("quickdraw.hook.swapBuyer"))
    uint256 internal constant SWAP_BUYER_SLOT = 0x5da8877fde8a3a6de0e453cd7cc6272d44774afefe8e5a5fe16267efeca06263;
    uint256 public constant SUPPLY = 100_000e18; // QuickdrawToken.SUPPLY: 100k DRAW, minted once; the caps are shares of it

    // QUICKDRAW-1 self-description: any tracker can recognize the game generically (ERC-165 below)
    string public constant STANDARD = "QUICKDRAW-1"; // the Quickdraw game standard: a balance is a hand on the street
    bytes4 public constant QUICKDRAW_INTERFACE_ID = bytes4(keccak256("QUICKDRAW-1"));

    // THE ONLY CHARGE ON A TRADE IS IN ETH, BOTH DIRECTIONS, ON ALL FOUR SWAP MODES, AND IT NEVER CHANGES:
    //   - DEV_TAX_BPS (2.5%) -> the treasury = the dev wallet, pushed in the same tx; permanent, no switch;
    //   - BOUNTY_FEE_BPS (1.5%) -> bountyPool; permanent, removable by nobody. The bounty is what every winner
    //     drinks from (BOUNTY_DRAW_BPS per kill) and what capAdmin may sweep to the dev wallet for a manual
    //     buyback (sweepBounty);
    //   - PLATFORM_BPS (0.30%) -> Programmable (PLATFORM_RECIPIENT), accrued here, paid by claimPlatform().
    // There is NO token-side fee: DRAW only ever burns through draws (95% of what a loser gives up) and idle
    // decay. Holders earn ETH by winning, never by holding (the accEthPerMass stream only re-apportions a
    // husk's forfeited kill ETH to survivors).
    uint16 public constant DEV_TAX_BPS    = 250;  // 2.5% of ETH-side volume -> the dev wallet (treasury)
    uint16 public constant BOUNTY_FEE_BPS = 150;  // 1.5% of ETH-side volume -> bountyPool, permanent
    uint16 public constant PLATFORM_BPS   = 30;   // 0.30% of ETH-side volume -> Programmable, permanent
    // Won ETH a hand leaves unclaimed this long after its owner was FIRST ALLOWED to claim it may be reclaimed by
    // capAdmin to the treasury (reclaimUnclaimed). The owner may claim once the ETH is banked AND the hand is past
    // FEE_WARMUP (1 hour old), so the clock starts at max(lastEthCreditAt, firstBornAt + FEE_WARMUP); every new credit
    // to the hand (a win, or stream ETH banked by a settle) restarts it. reclaimableAt(id) gives the exact moment.
    uint64 public constant UNCLAIMED_WINDOW = 1 hours;
    // ETH of swap volume that arms one draw (price-INDEPENDENT pacing): every 0.05 ETH traded on the ETH leg arms
    // one draw, so the street keeps moving at any market cap.
    uint256 public constant EAT_UNIT    = 0.05 ether;
    uint8   public constant MAX_DRAIN   = 4;       // max deferred draws armed/resolved per swap (bounded catch-up)
    // COMMIT->REVEAL delay in WALL-CLOCK SECONDS. An Ethereum slot is 12s, so this is "an armed draw resolves a
    // block later", expressed in seconds so it degrades gracefully across missed slots. The separation guarantee
    // itself comes from the BLOCK gate in _resolveEats, not from this number.
    uint32  public constant REVEAL_DELAY    = 12;
    // Armed draws older than this are DROPPED rather than resolved on stale flow. On Ethereum 10 minutes is
    // ~50 blocks, comfortably inside the 256-block (~51 min) blockhash window the reveal seed reads from.
    uint32  public constant EAT_STALE_AFTER = 10 minutes;
    // Launch anti-snipe: TWO independent guards on INCOMING transfers to non-excluded wallets, checked by the token
    // through beforeTokenTransfer. Neither can touch a draw: a draw moves balance RAW through gameMove/gameBurn,
    // never through transfer(), so a hand growing past a cap by WINNING is always allowed. The caps only bound
    // what a wallet can BUY / be sent, the initial buy of the launch included.
    //   1) MAX TX: no single incoming transfer (one buy) may exceed this share of supply. Until removeMaxTx(), once.
    uint16  public constant MAX_TX_BPS     = 50;         // 0.5% of supply per single buy/transfer (500 DRAW)
    //   2) MAX WALLET: no non-excluded wallet may HOLD more than this share of supply. Until removeMaxWallet(), once.
    uint16  public constant MAX_WALLET_BPS = 200;        // 2% of supply (2,000 DRAW)
    // THE LAUNCH PROTECTION PACKAGE, all fixed in code:
    //  - PROTECTION_WINDOW: for 300 s after the pool opens, a buy is accepted only from an AUTHENTICATED buyer (a
    //    trusted router whose msgSender() names the wallet, or the launcher's own initial buy naming BUYER in its
    //    hook data), and two CUMULATIVE limits of WINDOW_LIMIT_BPS (2% = 2,000 DRAW) bind every wallet: what it
    //    BOUGHT through swaps (windowBought) and what it RECEIVED, by buys and by ordinary transfers
    //    (windowReceived). Selling or sending out never frees room. They bind everyone: the launch wallet, the
    //    treasury, capAdmin and every excluded address included; only the pool side (the PoolManager) and this
    //    hook are outside them. Game moves (draws, decay) are neither purchases nor receipts and are not counted.
    //    During the window the exclusions bypass nothing; the two caps above apply to every recipient too.
    //  - OPENING FEE: on BUYS the total fee is OPENING_FEE_BPS (99%) when the pool opens and falls linearly to
    //    the normal 4.3% over OPENING_DECAY (30 s); the additional part goes to Programmable's fixed recipient
    //    (openingFeeOwed, paid by claimPlatform). At most MAX_OPENING_FEE_EXEMPT wallets, fixed at construction,
    //    are exempt from the additional part only: they pay 4.3% and stay bound by every limit.
    uint64  public constant PROTECTION_WINDOW = 300;      // seconds after launchTime
    uint16  public constant WINDOW_LIMIT_BPS  = 200;      // 2% of supply per wallet, cumulative, during the window
    uint16  public constant OPENING_FEE_BPS   = 9900;     // the total buy fee at launchTime (99%)
    uint64  public constant OPENING_DECAY     = 30;       // seconds for the additional part to fall to zero
    uint256 public constant MAX_OPENING_FEE_EXEMPT = 6;
    uint256 internal constant BASE_FEE_BPS    = 430;      // DEV_TAX_BPS + BOUNTY_FEE_BPS + PLATFORM_BPS

    IPoolManager public immutable poolManager;
    uint256 public cumulativeVolume;
    uint256 public nextEatAt = EAT_UNIT;
    uint256 public dishNonce;
    uint64  public pendingEats;     // draws armed (volume crossed) but not yet resolved
    uint64  public eatCommitTs;     // TIMESTAMP the pending draws were armed at (resolve only >= +REVEAL_DELAY)
    uint64  public eatCommitBlock;  // block the draws were armed in (resolve only in a strictly later block)

    PoolKey public poolKey;
    PoolId  public poolId;
    Currency public currency0;   // ETH
    Currency public currency1;   // DRAW (the token)
    bool public initialized;
    uint64 public launchTime;    // set in afterInitialize; the caps apply from here

    // The two launch caps. Each starts ON; each `remove*()` flips it OFF permanently (one-way, never re-armable).
    bool public maxTxOn = true;       // 0.5% per-buy cap    -> removeMaxTx()
    bool public maxWalletOn = true;   // 2% per-wallet cap   -> removeMaxWallet()
    uint256 public treasuryEthOwed;   // dev-tax / swept-bounty ETH accrued when the 2,300-gas push fails, awaiting sweepTreasuryEth()
    uint256 public platformOwed;      // Programmable's 0.30%, accrued here, paid by claimPlatform()
    uint256 public openingFeeOwed;    // the additional opening buy fee (first 30 s), Programmable's; paid by claimPlatform()
    mapping(address => uint256) public windowBought;   // DRAW bought through swaps by an authenticated buyer, in the window
    mapping(address => uint256) public windowReceived; // DRAW received by buys and transfers, in the window
    // The treasury (the dev wallet) receives 100% of the dev tax, always in ETH, pushed in the taxed swap itself,
    // with sweepTreasuryEth() as the fallback. Excluded from the game (never a hand). Immutable.
    address public immutable treasury;
    // The ONLY address with post-launch power. Exactly three powers plus one one-time link: the two one-way cap
    // switches (removeMaxTx, removeMaxWallet), the bounty lever (sweepBounty, which pays the treasury only) and
    // linkMirror (naming the NFT mirror once). It can NEVER raise or add a fee, move holder funds, mint, pause,
    // or change the treasury.
    address public immutable capAdmin;
    address public immutable PLATFORM_RECIPIENT; // Programmable's fee recipient (the 0.30% and the opening fee)
    // the wallets exempt from the additional opening fee only (unused slots are zero; see isOpeningFeeExempt)
    address internal immutable EXEMPT_0;
    address internal immutable EXEMPT_1;
    address internal immutable EXEMPT_2;
    address internal immutable EXEMPT_3;
    address internal immutable EXEMPT_4;
    address internal immutable EXEMPT_5;
    QuickdrawRenderer public immutable renderer;      // on-chain SVG, a graph target of its own
    address public immutable deployer;           // the launcher: gates afterInitialize and link()

    address public token;        // the QuickdrawToken, named once by the launcher (link)
    QuickdrawNFT public nft;          // the ERC-721 mirror, named once by capAdmin (linkMirror); optional
    bool public linked;

    // bloodstream egress (pull-only, CEI, guarded, OUTSIDE the PoolManager unlock)
    mapping(address => uint256) public ethEscrow; // wei owed to a recipient whose direct send reverted
    uint256 public ethEscrowTotal;                // sum of ethEscrow, part of bloodReserve (never stranded)
    uint256 private _ethLock = 1;                 // 1=unlocked, 2=locked (cheap non-reentrancy guard)

    event BountySwept(uint256 amount);  // capAdmin moved the whole standing bounty to the treasury (dev wallet)
    event EthReclaimed(uint256 indexed id, address indexed owner, uint256 amount); // won ETH unclaimed past the window -> treasury
    event EthPaid(address indexed to, uint256 amount);     // direct ETH send succeeded
    event EthEscrowed(address indexed to, uint256 amount); // recipient rejected -> pull-escrowed
    event EthEscrowClaimed(address indexed to, uint256 amount);
    event PlatformClaimed(address indexed to, uint256 amount); // Programmable's accrued share (0.30% + opening fee) was paid
    event MaxTxRemoved();     // the 0.5% per-buy cap was lifted (one-way)
    event MaxWalletRemoved(); // the 2% wallet cap was lifted (one-way)
    event TreasuryEthSwept(uint256 amount); // accrued dev-tax / swept-bounty ETH pushed to the treasury

    error OnlyPoolManager();
    error OnlyMirror();
    error OnlyToken();
    error NotDeployer();
    error Linked_();
    error AlreadyInit();
    error WrongPool();
    error HookNotImplemented();
    error Reentrancy();
    error NothingToClaim();
    error HandBound();
    error MaxWallet();
    error MaxTx();
    error NotCapAdmin();
    error CapAlreadyRemoved(); // a launch cap was already lifted (shared by removeMaxTx / removeMaxWallet)
    error ZeroAddress();
    error Unauthenticated();  // a buy in the protection window from a caller that does not name an authenticated wallet
    error BuyLimit();         // an authenticated buyer would pass 2% bought in the protection window
    error ReceiveLimit();     // a recipient would pass 2% received in the protection window
    error ProtectionWindow(); // a cap removal before the protection window is over
    error TooManyExempt();    // more than MAX_OPENING_FEE_EXEMPT opening-fee-exempt wallets

    /// `launcher_` holds the supply, opens the pool (afterInitialize gate) and names the token (link).
    /// `capAdmin_` is the ONLY post-launch privileged address. `treasury_` receives the dev tax; excluded, immutable.
    /// `platformRecipient_` receives PLATFORM_BPS through claimPlatform(). `renderer_` draws the NFT art.
    /// `exclusions` are extra addresses that may hold DRAW without being a hand (the mainnet infrastructure is
    /// baked in below; the token is excluded at link, the NFT mirror never holds DRAW). `openingFeeExempt`: at most
    /// six wallets (the launch wallet and the team) exempt from the additional opening fee only.
    constructor(
        IPoolManager _pm, address launcher_, address capAdmin_, address treasury_, address platformRecipient_,
        QuickdrawRenderer renderer_, address[] memory exclusions, address[] memory openingFeeExempt
    ) {
        if (launcher_ == address(0) || capAdmin_ == address(0) || treasury_ == address(0) || platformRecipient_ == address(0)) revert ZeroAddress();
        uint256 n = openingFeeExempt.length;
        if (n > MAX_OPENING_FEE_EXEMPT) revert TooManyExempt();
        address[6] memory e;
        for (uint256 i = 0; i < n; i++) {
            if (openingFeeExempt[i] == address(0)) revert ZeroAddress();
            e[i] = openingFeeExempt[i];
        }
        EXEMPT_0 = e[0];
        EXEMPT_1 = e[1];
        EXEMPT_2 = e[2];
        EXEMPT_3 = e[3];
        EXEMPT_4 = e[4];
        EXEMPT_5 = e[5];
        poolManager = _pm;
        deployer = launcher_;
        capAdmin = capAdmin_;
        treasury = treasury_;
        PLATFORM_RECIPIENT = platformRecipient_;
        renderer = renderer_;
        isExcluded[address(this)] = true;
        isExcluded[address(_pm)] = true;
        isExcluded[DEAD] = true;
        isExcluded[address(0)] = true;
        isExcluded[PERMIT2] = true;
        isExcluded[launcher_] = true;   // holds the supply, then the rounding dust: never a hand
        isExcluded[treasury_] = true;   // holds dev-tax proceeds, never plays the game
        isExcluded[UNIVERSAL_ROUTER] = true;
        isExcluded[UNIVERSAL_ROUTER_2] = true;
        isExcluded[POSITION_MANAGER] = true;
        isExcluded[PROGRAMMABLE_ROUTER] = true;
        isExcluded[GRAPH_FACTORY] = true;
        isExcluded[ROUTER_24H] = true;
        for (uint256 i = 0; i < exclusions.length; i++) isExcluded[exclusions[i]] = true;
    }

    modifier onlyPM() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlyNFT() {
        if (msg.sender != address(nft)) revert OnlyMirror();
        _;
    }

    modifier onlyToken() {
        if (msg.sender != token) revert OnlyToken();
        _;
    }

    /// Cheap non-reentrancy guard for the ETH egress paths (claimEth / escrow / spore pull / sweeps / platform).
    modifier nonReentrant() {
        if (_ethLock == 2) revert Reentrancy();
        _ethLock = 2;
        _;
        _ethLock = 1;
    }

    /// One-time: the launcher names the token inside initializeGraph (the only place its address is known on
    /// chain before the pool opens). The token is excluded from the game (it never holds DRAW) and becomes the
    /// only caller of beforeTokenTransfer / afterTokenTransfer.
    function link(address token_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (linked) revert Linked_();
        if (token_ == address(0)) revert ZeroAddress();
        token = token_;
        isExcluded[token_] = true;
        linked = true;
    }

    /// One-time: capAdmin names the ERC-721 mirror. The mirror must point back at this hook. It only enables the
    /// NFT view of a hand (events + tokenURI); the game runs identically without it.
    function linkMirror(QuickdrawNFT nft_) external {
        if (msg.sender != capAdmin) revert NotCapAdmin();
        if (address(nft) != address(0)) revert Linked_();
        if (address(nft_.base()) != address(this)) revert OnlyMirror();
        nft = nft_;
    }

    /*//////////////////// the token's two calls: balance-as-mass funnel ////////////////////*/

    /// Called by the token BEFORE every transfer / transferFrom moves a balance. A v4 buy lands as a transfer FROM
    /// the PoolManager TO the buyer, so checking the `to` side covers direct swaps, routers and the launcher's
    /// initial buy. The pool side (`to` = the PoolManager: sells, the launcher's seeding) and this hook are never
    /// limited, so SELLS are never restricted.
    ///   - In the PROTECTION WINDOW: what `to` has received in the window (windowReceived) may not pass 2%,
    ///     whoever it is (exclusions bypass nothing), and the two caps below apply to every recipient.
    ///   - MAX TX     : one transfer may not exceed MAX_TX_BPS of supply. Lives until removeMaxTx() (one-way).
    ///   - MAX WALLET : a wallet may not end up holding more than MAX_WALLET_BPS of supply. Lives until
    ///                  removeMaxWallet() (one-way). After the window, excluded infrastructure is exempt from both.
    /// Game moves (gameMove / gameBurn) never come through here, so draws and decay are never counted.
    function beforeTokenTransfer(address, address to, uint256 amount) external onlyToken {
        uint256 opened = launchTime;
        if (opened == 0 || to == address(poolManager) || to == address(this)) return; // pre-launch, or the pool side
        if (block.timestamp < opened + PROTECTION_WINDOW) {
            uint256 got = windowReceived[to] + amount;
            if (got > SUPPLY * WINDOW_LIMIT_BPS / BPS) revert ReceiveLimit();
            windowReceived[to] = got;
        } else if (isExcluded[to]) {
            return; // after the window, exempt infrastructure
        }
        if (maxTxOn && amount > SUPPLY * MAX_TX_BPS / BPS) revert MaxTx();
        if (maxWalletOn && IQuickdrawToken(token).balanceOf(to) + amount > SUPPLY * MAX_WALLET_BPS / BPS) revert MaxWallet();
    }
    /// Called by the token AFTER the balance moved: resync both hands. _resync is balance-pure (no token moves,
    /// no PM interaction), so it is safe inside the v4 unlock and can never brick a transfer.
    function afterTokenTransfer(address from, address to) external onlyToken {
        _afterBalance(from, to);
    }

    /// Lift the 0.5% per-buy cap, permanently. One-way, capAdmin only, never inside the protection window.
    function removeMaxTx() external {
        if (msg.sender != capAdmin) revert NotCapAdmin();
        _afterWindow();
        if (!maxTxOn) revert CapAlreadyRemoved();
        maxTxOn = false;
        emit MaxTxRemoved();
    }

    /// Lift the 2% max-wallet cap, permanently. One-way, capAdmin only, never inside the protection window.
    function removeMaxWallet() external {
        if (msg.sender != capAdmin) revert NotCapAdmin();
        _afterWindow();
        if (!maxWalletOn) revert CapAlreadyRemoved();
        maxWalletOn = false;
        emit MaxWalletRemoved();
    }

    /// Move the ENTIRE standing bounty to the treasury (the dev wallet) for a manual buyback. capAdmin only,
    /// guarded, OUTSIDE any PoolManager unlock. The wei leaves the bloodstream through ethOut, so
    /// bloodReserve() (= ethIn - ethOut + escrow) stays exact, and it goes out through the same 2,300-gas push
    /// as the dev tax: a treasury that cannot take it books treasuryEthOwed for sweepTreasuryEth(), never a
    /// revert that could trap the pool. Holder-claimable ETH (handEth, bloodClaimable, escrow) and Programmable's
    /// platformOwed are out of its reach. A draw settled right after a sweep pays a 0 prize and still resolves.
    function sweepBounty() external nonReentrant returns (uint256 amount) {
        if (msg.sender != capAdmin) revert NotCapAdmin();
        amount = bountyPool;
        if (amount == 0) revert NothingToClaim();
        bountyPool = 0;
        ethOut += amount;
        _payTreasuryEth(amount);
        emit BountySwept(amount);
    }

    /// The moment the ETH of hand `id` becomes reclaimable by capAdmin: UNCLAIMED_WINDOW (1 hour) after the owner was
    /// first allowed to claim it, i.e. after max(lastEthCreditAt[id], firstBornAt[id] + FEE_WARMUP). Stream ETH not yet
    /// banked counts as credited now, because the next settle (a reclaim's own included) banks and stamps it, so for
    /// such a hand this moves with the clock until something settles it. 0 when the hand holds no ETH at all (banked
    /// or pending). The site and the tools read this one number; reclaimUnclaimed uses it too.
    function reclaimableAt(uint256 id) public view returns (uint64) {
        uint64 credit = lastEthCreditAt[id];
        if (_pendingEth(id) > 0) credit = uint64(block.timestamp);
        else if (handEth[id] == 0) return 0;
        uint64 warm = firstBornAt[id] + FEE_WARMUP;
        return (credit > warm ? credit : warm) + UNCLAIMED_WINDOW;
    }

    /// Take the banked ETH (handEth) of hands that left it unclaimed for UNCLAIMED_WINDOW after it became claimable
    /// (reclaimableAt), and pay it to the treasury (the dev wallet). capAdmin only, guarded, OUTSIDE any PoolManager
    /// unlock.
    ///
    /// Per id: the hand's pending stream ETH is banked first (_settleEth), so nothing hides in the accumulator; a
    /// settle that banks something IS a credit and restarts the window, so such a hand is skipped on this call.
    /// Then, if handEth[id] > 0 and block.timestamp >= reclaimableAt(id), it is zeroed and counted. Ids that are not yet eligible,
    /// hold nothing, or never existed are skipped silently: one stale id never blocks a batch. The total leaves the
    /// bloodstream through ethOut (bloodReserve() stays exact) and goes out through the same 2,300-gas push as the dev
    /// tax, with the treasuryEthOwed fallback. It never touches DRAW balances, spores (bloodClaimable), escrow,
    /// platformOwed or the bountyPool, and never runs decay. The owner's claimEth works exactly as before until the
    /// moment of a reclaim; after it there is nothing to claim until the hand wins again.
    function reclaimUnclaimed(uint256[] calldata ids) external nonReentrant returns (uint256 total) {
        if (msg.sender != capAdmin) revert NotCapAdmin();
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            _settleEth(id);
            uint256 amount = handEth[id];
            if (amount == 0 || block.timestamp < reclaimableAt(id)) continue;
            handEth[id] = 0;
            handEthTotal -= amount;
            total += amount;
            emit EthReclaimed(id, address(uint160(id)), amount); // a hand's id is its owner's address
        }
        if (total == 0) return 0;
        ethOut += total;
        _payTreasuryEth(total);
    }

    /// Push accrued dev-tax / swept-bounty ETH that the inline push could not deliver. Permissionless (funds only
    /// ever go to `treasury`), CEI, re-entrancy-guarded, OUTSIDE any PoolManager unlock. Sends ONLY
    /// treasuryEthOwed, so holder ETH and platformOwed can never be touched.
    function sweepTreasuryEth() external nonReentrant returns (uint256 amount) {
        amount = treasuryEthOwed;
        if (amount == 0) revert NothingToClaim();
        treasuryEthOwed = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "treasury eth");
        emit TreasuryEthSwept(amount);
    }

    /// Anyone: pay Programmable its accrued PLATFORM_BPS share, as plain ETH. Nothing owed -> returns 0, no revert.
    /// A recipient that rejects the push leaves the amount owed (the revert restores it); nothing else is touched.
    function claimPlatform() external nonReentrant returns (uint256 amount) {
        amount = platformOwed + openingFeeOwed; // the 0.30% leg and the opening fee, both Programmable's
        if (amount == 0) return 0;
        platformOwed = 0;
        openingFeeOwed = 0;
        (bool ok,) = PLATFORM_RECIPIENT.call{value: amount}("");
        require(ok, "platform eth");
        emit PlatformClaimed(PLATFORM_RECIPIENT, amount);
    }

    /*//////////////////// QuickdrawGame token primitives (the token does the moves) ////////////////////*/

    function _holderBalance(address who) internal view override returns (uint256) { return IQuickdrawToken(token).balanceOf(who); }

    /// RAW loser -> winner move inside the draw (NO resync; the draw reconciles state itself).
    function _moveMass(address from, address to, uint256 amount) internal override {
        if (amount == 0) return;
        IQuickdrawToken(token).gameMove(from, to, amount);
    }

    /// RAW burn from a holder (draw/decay). Shrinks totalSupply; never touches DEAD.
    function _burnMass(address from, uint256 amount) internal override {
        if (amount == 0) return;
        IQuickdrawToken(token).gameBurn(from, amount);
    }

    /// Pay DRAW out of the hook's apex-fee reserve to `to`, then resync `to`. There is no token-side fee under
    /// this model, so the reserve is always 0 and this never moves anything; kept so the street's accounting stays
    /// exact if it ever did.
    function _payout(address to, uint256 amount) internal override {
        if (amount == 0) return;
        IQuickdrawToken(token).gameMove(address(this), to, amount);
        _resync(to);
    }

    /// Hand dev-tax ETH (and a swept bounty) straight to the treasury, in the same transaction that produced it.
    ///
    /// THE TREASURY IS PAID IN ETH ONLY, NEVER IN DRAW. The 2,300 gas stipend is doing real work here: this runs
    /// INSIDE the v4 unlock, mid-swap, so a treasury that could execute arbitrary code would be re-entering the
    /// PoolManager in the middle of a swap. 2,300 gas is enough for a plain EOA to accept ETH and not enough to
    /// call anything back. If the send fails for any reason (a contract treasury such as a Safe, or a future
    /// gas-schedule change) the wei falls back to `treasuryEthOwed` for `sweepTreasuryEth()`. So the money is
    /// never lost and a treasury that cannot receive ETH can never brick trading.
    function _payTreasuryEth(uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = treasury.call{value: amount, gas: 2300}("");
        if (ok) emit TreasuryEthSwept(amount);
        else treasuryEthOwed += amount; // deferred to sweepTreasuryEth(); never lost, never blocks the swap
    }

    /// Charge the ETH fee on `base` (the ETH side of the swap) with divisor `den`: BPS when the fee is a share
    /// of the amount, BPS - bps when the swap is grossed up (exact-output sell; exact-output buy during the
    /// opening). Takes the ETH from the PoolManager, pushes the dev share (2.5%) to the treasury in the same tx,
    /// parks the bounty share (1.5%) in bountyPool, accrues Programmable's share (0.30%) in platformOwed and the
    /// additional opening fee (`extraBps`, buys in the first 30 s only) in openingFeeOwed. Returns the total taken,
    /// i.e. the hook's delta.
    function _takeEthFee(uint256 base, uint256 den, uint256 extraBps) internal returns (uint256 total) {
        uint256 dev = base * DEV_TAX_BPS / den;
        uint256 bounty = base * BOUNTY_FEE_BPS / den;
        uint256 platform = base * PLATFORM_BPS / den;
        uint256 opening = base * extraBps / den;
        total = dev + bounty + platform + opening;
        if (total == 0) return 0;
        currency0.take(poolManager, address(this), total, false);
        _payTreasuryEth(dev);
        _intakeBlood(bounty);
        platformOwed += platform;
        if (opening > 0) openingFeeOwed += opening;
    }

    /*//////////////////// the launch protection package ////////////////////*/

    /// True while the protection window runs (from launchTime, for PROTECTION_WINDOW seconds).
    function _inWindow() internal view returns (bool) {
        uint256 opened = launchTime;
        return opened != 0 && block.timestamp < opened + PROTECTION_WINDOW;
    }

    function _afterWindow() internal view {
        uint256 opened = launchTime;
        if (opened == 0 || block.timestamp < opened + PROTECTION_WINDOW) revert ProtectionWindow();
    }

    /// The additional opening buy fee right now, in bps of the ETH leg, for a buyer that is not exempt: the total
    /// buy fee is OPENING_FEE_BPS at launchTime and falls linearly to BASE_FEE_BPS at launchTime + OPENING_DECAY;
    /// this is the part above BASE_FEE_BPS. 0 before the launch and from OPENING_DECAY on.
    function openingFeeBps() public view returns (uint256) {
        uint256 opened = launchTime;
        if (opened == 0) return 0;
        uint256 elapsed = block.timestamp - opened;
        if (elapsed >= OPENING_DECAY) return 0;
        return (OPENING_FEE_BPS - BASE_FEE_BPS) * (OPENING_DECAY - elapsed) / OPENING_DECAY;
    }

    /// Whether `wallet` is one of the (at most six) wallets exempt from the additional opening fee.
    function isOpeningFeeExempt(address wallet) public view returns (bool) {
        return wallet != address(0) && (wallet == EXEMPT_0 || wallet == EXEMPT_1 || wallet == EXEMPT_2
            || wallet == EXEMPT_3 || wallet == EXEMPT_4 || wallet == EXEMPT_5);
    }

    /// The authenticated buyer of a swap: the wallet the launcher names in its hook data (its own initial buy), or
    /// the wallet a trusted router names through msgSender(). Zero for anyone else.
    function _buyer(address sender, bytes calldata hookData) internal view returns (address wallet) {
        if (sender == deployer) {
            if (hookData.length == 32) {
                uint256 v = abi.decode(hookData, (uint256));
                if (v <= type(uint160).max) wallet = address(uint160(v));
            }
        } else if (sender == UNIVERSAL_ROUTER || sender == UNIVERSAL_ROUTER_2 || sender == PROGRAMMABLE_ROUTER) {
            wallet = _callerOf(sender);
        }
    }

    /// The wallet a router says it acts for (msgSender()), read with a bounded call that never reverts: zero when
    /// the router does not answer, answers with something else than one word, or names an impossible address.
    function _callerOf(address router) internal view returns (address w) {
        (bool ok, bytes memory ret) = router.staticcall{gas: 30_000}(abi.encodeWithSelector(MSG_SENDER_SELECTOR));
        if (!ok || ret.length != 32) return address(0);
        uint256 v = abi.decode(ret, (uint256));
        if (v <= type(uint160).max) w = address(uint160(v));
    }

    /// The buyer of the swap in flight, carried from beforeSwap to afterSwap in transient storage (one swap at a
    /// time per hook call pair; beforeSwap always writes it for a buy).
    function _setSwapBuyer(address wallet) internal {
        assembly ("memory-safe") { tstore(SWAP_BUYER_SLOT, wallet) }
    }

    function _swapBuyer() internal view returns (address wallet) {
        assembly ("memory-safe") { wallet := tload(SWAP_BUYER_SLOT) }
    }
    /*//////////////////// ERC-721 mirror bridge (IQuickdrawBase) ////////////////////*/

    function _onHandMint(uint256 id, address owner) internal override {
        if (address(nft) != address(0)) nft.emitTransfer(address(0), owner, id);
    }
    function _onHandBurn(uint256 id, address owner) internal override {
        if (address(nft) != address(0)) nft.emitTransfer(owner, address(0), id);
    }
    function _onHandSync(uint256 id) internal override {
        if (address(nft) != address(0)) nft.emitMetadataUpdate(id); // ERC-4906 refresh on a draw
    }
    function handOwnerOf(uint256 id) external view returns (address) {
        if (!hands[id].alive) revert Dead();
        return hands[id].owner;
    }
    function handBalanceOf(address owner) external view returns (uint256) {
        return hands[_idOf(owner)].alive ? 1 : 0;
    }
    function handTokenURI(uint256 id) external view returns (string memory) {
        if (!hands[id].alive) revert Dead();
        return renderer.tokenURI(id, hands[id].mass, hands[id].kills);
    }
    /// QUICKDRAW-1 hands are address-bound: the hand follows the DRAW balance, it cannot be sold apart from it.
    /// The NFT is a live view of your wallet; transferring it is meaningless, so it reverts.
    function mirrorTransfer(address, address, uint256) external onlyNFT { revert HandBound(); }

    /*//////////////////// public: claims ////////////////////*/

    /// Claim your hand's accrued DRAW apex fees (warm only). Always 0 under this fee model; kept for the street.
    function claim() external returns (uint256 fees) {
        fees = _claim(_idOf(msg.sender), msg.sender);
        _payout(msg.sender, fees);
    }

    /// Claim the ETH your hand banked by winning (bounty prize + the loser's banked ETH). Pull-only, CEI,
    /// guarded, OUTSIDE any PoolManager unlock. A recipient that rejects the ETH is escrowed to a pull bucket.
    function claimEth() external nonReentrant returns (uint256 amount) {
        amount = _claimEth(_idOf(msg.sender), msg.sender);
        if (amount == 0) revert NothingToClaim();
        _sendEth(msg.sender, amount);
    }

    /// Pull any escrowed (previously-undeliverable) ETH. CEI + guarded.
    function claimEscrow() external nonReentrant returns (uint256 amount) {
        amount = ethEscrow[msg.sender];
        if (amount == 0) revert NothingToClaim();
        ethEscrow[msg.sender] = 0;
        ethEscrowTotal -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth escrow pull");
        emit EthEscrowClaimed(msg.sender, amount);
    }

    /// Pull the ETH spore owed to you from hands of yours that lost a draw. Pull-only, CEI, guarded.
    function claimSpore() external nonReentrant returns (uint256 amount) {
        amount = bloodClaimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        bloodClaimable[msg.sender] = 0;
        bloodClaimableTotal -= amount;
        ethOut += amount;
        _sendEth(msg.sender, amount); // escrows on a rejecting recipient (never bricks)
    }

    /// Send ETH the street has ALREADY accounted as paid out (ethOut bumped, handEth zeroed). Rejecting recipient
    /// -> move the SAME wei into a pull-escrow bucket (never bricks, never lost; stays inside bloodReserve via
    /// ethEscrowTotal). Gas-capped at 30k.
    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: 30_000}("");
        if (ok) {
            emit EthPaid(to, amount);
        } else {
            ethEscrow[to] += amount;
            ethEscrowTotal += amount;
            emit EthEscrowed(to, amount);
        }
    }

    /*//////////////////// the swap engine (internal) ////////////////////*/

    function _processSwap(uint256 volumeInEth) internal {
        // resolve draws armed in an earlier block FIRST (deferred so the draw cannot be aimed)
        _resolveEats();
        cumulativeVolume += volumeInEth;
        // ARM draws (do NOT draw in this tx): commit to resolving REVEAL_DELAY seconds later. Bounded so a fat
        // swap cannot burst-harvest draws; the volume threshold catches up over subsequent swaps. Live from launch.
        if (liveMass > 0) {
            while (cumulativeVolume >= nextEatAt && pendingEats < MAX_DRAIN) {
                nextEatAt += EAT_UNIT;
                unchecked { pendingEats += 1; }
                eatCommitTs = uint64(block.timestamp);
                eatCommitBlock = uint64(block.number);
            }
        }
    }

    /// Resolve draws armed >= REVEAL_DELAY seconds earlier, seeded from the hash of the block the draws were
    /// ARMED IN, a value that did not exist yet at arm time and is frozen forever once that block seals.
    ///
    /// THE SEED IS PINNED TO THE COMMIT, NOT TO THE REVEAL. Once the arming block seals, the outcome is FIXED:
    /// waiting changes nothing, extra swaps change nothing, the only choice left is resolve or don't resolve, and
    /// declining just leaves the draws for the next trader's swap (or for the staleness drop). The proposer of
    /// the ARMING block keeps one shot at biasing a draw armed inside it (the standard floor for on-chain
    /// randomness without a VRF); the seed only randomises SELECTION AMONG bucket occupants, the percentage floor
    /// and KILL_COOLDOWN cap the payoff, and 95% of taken mass is burned.
    ///
    /// BLOCK TIME: an Ethereum slot is 12s, so the two reveal gates below (>= 12s of wall clock, and a strictly
    /// later block) land on the SAME block, the next one. The block gate is what guarantees
    /// `blockhash(eatCommitBlock)` is readable at all; REVEAL_DELAY is only a floor.
    function _resolveEats() internal {
        uint256 pe = pendingEats;
        if (pe == 0) return;
        if (block.timestamp < uint256(eatCommitTs) + REVEAL_DELAY) return;
        if (block.number <= uint256(eatCommitBlock)) return;
        pendingEats = 0;
        if (liveMass == 0) return; // nothing to draw on; drop the armed draws
        // staleness: after a long idle gap, drop the armed draws instead of resolving on stale flow.
        if (block.timestamp > uint256(eatCommitTs) + EAT_STALE_AFTER) return;
        // seal := hash of the block the draws were armed in. EAT_STALE_AFTER (10 min ~= 50 blocks) keeps this well
        // inside the 256-block blockhash window, so the zero-guard below should be unreachable, but a zero seal
        // would make every draw deterministic, so it is checked rather than assumed.
        bytes32 seal = blockhash(uint256(eatCommitBlock));
        if (seal == bytes32(0)) return; // out of the blockhash window: drop, never resolve on a zero seed
        for (uint256 i = 0; i < pe; i++) {
            unchecked { dishNonce += 1; }
            uint256 eatSeed = uint256(keccak256(abi.encode(seal, dishNonce, i)));
            _eat(eatSeed);
        }
    }

    /// KEEPER POKE: resolve due draws WITHOUT swapping. Permissionless: anyone may call it, any time. It can only
    /// do what a swap would already have done, on the same commit-pinned seed, with the same gates; calling it
    /// earlier or later cannot change WHO loses, only WHEN it is recorded. If no keeper runs, the game degrades
    /// to "the next trader's swap resolves" rather than stopping.
    function resolveEats() external {
        _resolveEats();
    }

    /// True when resolveEats() would actually do work right now.
    function eatsDue() external view returns (bool) {
        if (pendingEats == 0) return false;
        if (block.timestamp < uint256(eatCommitTs) + REVEAL_DELAY) return false;
        return block.number > uint256(eatCommitBlock);
    }

    /*//////////////////// v4 hook callbacks ////////////////////*/

    // The permissions are read by v4 from the address bits, CREATE2-mined to exactly AFTER_INITIALIZE |
    // BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA (the callbacks below).

    /// Only the launcher may open the pool (v4's initialize is permissionless; a stranger could otherwise open
    /// the canonical pool at a hostile price), and only the native ETH / DRAW pool with this hook.
    function afterInitialize(address sender, PoolKey calldata key, uint160, int24) external onlyPM returns (bytes4) {
        if (initialized) revert AlreadyInit();
        if (sender != deployer) revert NotDeployer();
        if (Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != token) revert WrongPool();
        initialized = true;
        launchTime = uint64(block.timestamp); // the caps apply from here
        poolKey = key;
        poolId = key.toId();
        currency0 = key.currency0; // ETH
        currency1 = key.currency1; // DRAW
        return IHooks.afterInitialize.selector;
    }

    /// When ETH is the swap's UNSPECIFIED currency (exact-out buy, exact-in sell) take the ETH fee here
    /// (exact-IN: that is the OUTPUT; exact-OUT: the INPUT). Feeing the MAGNITUDE of the unspecified delta,
    /// not only its positive/output case, closes the exact-output 0-fee bypass so EVERY swap pays. When the
    /// unspecified side is DRAW nothing is taken here: beforeSwap already took the ETH fee off the specified
    /// side. ETH-side volume drives the draw in BOTH directions, price-independent.
    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external onlyPM returns (bytes4, int128)
    {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        uint256 ethVol = uint256(int256(a0 < 0 ? -a0 : a0)); // ETH-side volume drives the draw (price-independent)
        bool buy = params.zeroForOne; // currency0 is ETH: a buy pays ETH for DRAW

        // The hook may only return a delta in the v4 UNSPECIFIED slot, so the fee is taken there. The
        // unspecified currency is DRAW when (zeroForOne == exactInput); its delta is the OUTPUT for an
        // exact-in swap (positive) or the INPUT for an exact-out swap (negative). We fee its MAGNITUDE so
        // exact-output swaps can no longer slip through fee-free.
        bool unspecIsDraw = (buy == (params.amountSpecified < 0));
        int128 unspecAmt = unspecIsDraw ? a1 : a0;
        uint256 feeBase = uint256(int256(unspecAmt < 0 ? -unspecAmt : unspecAmt));

        // THE FEE IS NEVER TAKEN IN DRAW. `unspecIsDraw` true means ETH was the SPECIFIED currency, so
        // beforeSwap already charged the ETH fee; charging again here would double-bill.
        int128 hookDelta = 0;
        if (!unspecIsDraw) {
            if (buy) {
                // exact-output BUY: during the opening the fee is grossed up so that it is the stated share of what
                // the buyer pays, exactly like an exact-input buy (fee = net * bps / (BPS - bps)); afterwards the
                // normal fee is a share of the pool's ETH input, as always.
                uint256 extra = _extraFor(_swapBuyer());
                uint256 den = extra == 0 ? BPS : BPS - BASE_FEE_BPS - extra;
                hookDelta = int128(uint128(_takeEthFee(feeBase, den, extra)));
            } else {
                hookDelta = int128(uint128(_takeEthFee(feeBase, BPS, 0))); // exact-input SELL: normal fee only
            }
        }
        // the protection window: the authenticated buyer's cumulative purchases (a buy's DRAW is a1 > 0)
        if (buy && _inWindow()) {
            address wallet = _swapBuyer();
            uint256 had = windowBought[wallet] + uint256(int256(a1));
            if (had > SUPPLY * WINDOW_LIMIT_BPS / BPS) revert BuyLimit();
            windowBought[wallet] = had;
        }
        _processSwap(ethVol);
        return (IHooks.afterSwap.selector, hookDelta);
    }

    /// The additional opening fee for this buyer right now: 0 for an exempt wallet.
    function _extraFor(address wallet) internal view returns (uint256) {
        return isOpeningFeeExempt(wallet) ? 0 : openingFeeBps();
    }

    // Unused callbacks: their flags are OFF in the mined address, so v4 never calls them.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) { revert HookNotImplemented(); }
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }

    /// THE ETH FEE WHEN ETH IS THE SPECIFIED CURRENCY, the reason this callback exists at all.
    ///
    /// v4 only lets `afterSwap` take its cut in the UNSPECIFIED currency, and on an ordinary exact-input buy
    /// (ETH -> DRAW) the unspecified currency IS DRAW. To keep every fee 100% ETH, it is skimmed off the ETH
    /// INPUT here instead, before the swap runs: v4 computes `amountToSwap += hookDeltaSpecified`, so a POSITIVE
    /// specified delta on an exact-input swap shrinks the input that reaches the pool by exactly what this hook
    /// took. Fires for the two modes where ETH is the SPECIFIED currency (exact-input buy, exact-output sell).
    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata hookData)
        external onlyPM returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool buy = params.zeroForOne;
        if (buy) {
            // the protection window: only an authenticated buyer may buy; carry the wallet to afterSwap
            address wallet;
            if (_inWindow()) {
                wallet = _buyer(sender, hookData);
                if (wallet == address(0)) revert Unauthenticated();
            }
            _setSwapBuyer(wallet);
        }
        if (buy == (params.amountSpecified < 0)) {
            uint256 total;
            if (buy) {
                // exact-input BUY: bps/BPS of the ETH the trader put in; in the first 30 s the opening part on top
                total = _takeEthFee(uint256(-params.amountSpecified), BPS, _extraFor(_swapBuyer()));
            } else {
                // exact-output SELL: the trader demands X ETH out. Gross the swap up to X + fee so that the fee
                // is bps/BPS of what the pool actually releases: fee = X * bps / (BPS - bps). Sells pay the normal fee.
                total = _takeEthFee(uint256(params.amountSpecified), BPS - BASE_FEE_BPS, 0);
            }
            if (total > 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(total)), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert HookNotImplemented(); }

    /*//////////////////// QUICKDRAW-1 detection surface ////////////////////*/

    /// ERC-165: advertises ERC-165 itself and the QUICKDRAW-1 interface id.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == QUICKDRAW_INTERFACE_ID; // ERC-165 || QUICKDRAW-1
    }

    /// The ETH the bloodstream owns: the un-paid-out wei (`ethIn - ethOut`: banked wins + parked bounty +
    /// spores owed) plus the pull-escrow bucket. platformOwed, openingFeeOwed and treasuryEthOwed are separate
    /// liabilities; address(this).balance always covers all four.
    function bloodReserve() public view override returns (uint256) {
        return (ethIn - ethOut) + ethEscrowTotal;
    }

    receive() external payable {}
}
