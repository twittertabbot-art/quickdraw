// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {QuickdrawGame} from "./QuickdrawGame.sol";
import {QuickdrawNFT} from "./QuickdrawNFT.sol";
import {QuickdrawRenderer} from "./QuickdrawRenderer.sol";
import {BaseLaunchProtectionModuleV1} from "./base-custom-v1/BaseLaunchProtectionModuleV1.sol";
import {ProtectedLaunchTokenV1} from "./launch-protection/ProtectedLaunchTokenV1.sol";
import {EthereumNativeFeeVaultV3} from "./ethereum-native30-v3/EthereumNativeFeeVaultV3.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// The token, as the hook sees it: the protected-launch surface it reads, the one-time binding, balances, and the
/// two raw moves only the game may make.
interface IQuickdrawToken {
    function initializer() external view returns (address);
    function poolManager() external view returns (address);
    function startedAt() external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
    function bindGame() external;
    function gameMove(address from, address to, uint256 amount) external;
    function gameBurn(address from, uint256 amount) external;
}

/// The read-only module interface of Programmable's sealed native kernel (ProtectedNative30HookV1), unchanged.
interface IProtectedNativeFeeModuleV1 {
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24);
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external view returns (bytes4, int128);
}

/*//////////////////////////////////////////////////////////////////////////
        QUICKDRAW // the game: the street, and the v4 hook of the DRAW pool
//////////////////////////////////////////////////////////////////////////*/
/*
  Two hats, one address: the street (balance-as-mass: a wallet's DRAW balance is its hand on the street) and the
  KERNEL of the one native ETH / DRAW pool, built on Programmable's protected launch package (launch protection v1).

  THE KERNEL mirrors Programmable's ProtectedNative30HookV1 swap path line for line:
    - beforeInitialize: only the fixed initializer (BaseProtectedNativeInitializerV1) may open the exact bound PoolKey,
      once, at initialSqrtPriceX96.
    - the fee is charged on the native leg, gross, rounded UP per trade, in all four swap shapes
      (quoteFees / previewTradeFees / _quoteTradeFees, the same maths): the 30-bps platform fee
      ceil(gross * 30 / 10000), the normal total ceil(gross * 430 / 10000) (PLATFORM_FEE_BPS + CREATOR_FEE_BPS), and
      during the first 30 seconds of a non-exempt BUY the opening tax on top (99% total at the start, linear to the
      normal fee at +30 s, the rate read from the protection module).
    - the immutable protection module (BaseLaunchProtectionModuleV1, CREATE child 2) authenticates every buy in the first
      300 seconds (a runtime-pinned router's msgSender(), or the initializer's atomic initial buy naming the
      developer) and sets the opening tax; this kernel binds both to its single active swap, checks the module's
      code hash on every call, and limits each authenticated buyer to the token's walletTokenLimit (2%) of
      cumulative purchases in those 300 seconds (boughtDuringProtection), so redirecting delivery cannot multiply
      one buyer's allowance.
    - CUSTODY, segregated: the platform fee and the dev's 2.5% are funded as native ERC-6909 claims of the normal
      fee vault (EthereumNativeFeeVaultV3, CREATE child 1: platform ledger -> PLATFORM_RECIPIENT, creator ledger ->
      the treasury); the opening tax is funded into a SEPARATE vault of the same code (CREATE child 3), platform
      ledger only, payable only to PLATFORM_RECIPIENT. Each vault pays out through its own permissionless
      claimPlatform() / claimCreator() to its fixed recipients. This contract holds none of those fees.
  The kernel has no swap, unlock-forwarding, delegatecall, arbitrary-call or privileged execution path.

  THE GAME keeps its own share of the project fee: of the 4.0% creator part, 2.5 points (DEV_TAX_BPS) go to the
  normal vault for the treasury and 1.5 points (BOUNTY_FEE_BPS) are taken here as native ETH into the standing
  bounty every winner drinks from. The same afterSwap arms a volume-paced draw that resolves a block later off a
  sealed seed. The token (QuickdrawToken) asks this hook before every transfer (the two launch caps) and tells it
  afterwards (the resync), and lets only this hook move or burn balances raw (draws, decay).

  ETH custody, asserted relentlessly: this contract holds ONLY game ETH it has not yet paid out, never holder mass:
      address(this).balance >= bloodReserve()
      bloodReserve() == ethIn - ethOut + escrow
  The pool's liquidity belongs to the initializer (a locked position with no removal path); this hook adds none.
*/
contract QuickdrawHook is QuickdrawGame, IHooks {
    using LPFeeLibrary for uint24;

    uint256 public constant POLICY_REVISION = 2;
    IPoolManager public immutable poolManager;
    uint256 public immutable CHAIN_ID;
    address public immutable CANONICAL_POOL_MANAGER;
    address public constant PLATFORM_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da; // Programmable's treasury
    uint16 public constant PLATFORM_FEE_BPS = 30;
    uint16 public constant FEE_DENOMINATOR = 10_000;
    bytes32 public constant FEE_PROFILE = keccak256("programmable.protected-native-fee.v1.gross-native.ceil-per-trade");

    /// The kernel's pool configuration, the same shape as ProtectedNative30HookV1.PoolConfig.
    struct PoolConfig {
        address token;
        uint24 lpFee;
        int24 tickSpacing;
        uint160 initialSqrtPriceX96;
        address initializer;
        address creatorFeeRecipient;
        uint16 creatorBuyFeeBps;
        uint16 creatorSellFeeBps;
        address module;
        uint24 maxModuleLpFeePips;
    }

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // Permit2, the canonical universal approval conduit, same address on every chain (9,152 bytes on Base).
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // Base (chain 8453) Uniswap infrastructure that may hold or route DRAW without ever being a hand on the street.
    // Programmable's trading router is the `router` constructor argument (excluded below); its Graph Factory and
    // 24h Router come in through `exclusions`.
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;   // Uniswap, v4-aware
    address internal constant UNIVERSAL_ROUTER_2 = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD; // older, still used by front ends
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;   // Uniswap v4 PositionManager
    uint256 internal constant SUPPLY = 100_000e18; // QuickdrawToken.SUPPLY: 100k DRAW, minted once; the caps are shares of it

    // QUICKDRAW-1 self-description: any tracker can recognize the game generically (ERC-165 below)
    string public constant STANDARD = "QUICKDRAW-1"; // the Quickdraw game standard: a balance is a hand on the street
    bytes4 public constant QUICKDRAW_INTERFACE_ID = bytes4(keccak256("QUICKDRAW-1"));

    // THE ONLY CHARGE ON A TRADE IS IN ETH, BOTH DIRECTIONS, ON ALL FOUR SWAP MODES, AND IT NEVER CHANGES:
    //   - PLATFORM_FEE_BPS (0.30%) -> Programmable, the normal vault's platform ledger;
    //   - DEV_TAX_BPS (2.5%) -> the treasury = the dev wallet, the normal vault's creator ledger (claimCreator);
    //   - BOUNTY_FEE_BPS (1.5%) -> bountyPool, here; permanent, removable by nobody. The bounty is what every winner
    //     drinks from (BOUNTY_DRAW_BPS per kill) and what capAdmin may sweep to the dev wallet for a manual
    //     buyback (sweepBounty).
    // DEV_TAX_BPS + BOUNTY_FEE_BPS = CREATOR_FEE_BPS (4.0%), the kernel's creator rate for buys and sells; the
    // creator fee of a trade is split pro rata, the bounty share rounded down. There is NO token-side fee: DRAW only
    // ever burns through draws (95% of what a loser gives up) and idle decay. Holders earn ETH by winning, never by
    // holding (the accEthPerMass stream only re-apportions a husk's forfeited kill ETH to survivors).
    uint16 public constant DEV_TAX_BPS     = 250;  // 2.5% of the gross native leg -> the dev wallet (treasury), via the normal vault
    uint16 public constant BOUNTY_FEE_BPS  = 150;  // 1.5% of the gross native leg -> bountyPool, permanent
    uint16 internal constant CREATOR_FEE_BPS = 400;  // DEV_TAX_BPS + BOUNTY_FEE_BPS: the kernel's creatorBuyFeeBps / creatorSellFeeBps
    // Won ETH a hand leaves unclaimed this long after its owner was FIRST ALLOWED to claim it may be reclaimed by
    // capAdmin to the treasury (reclaimUnclaimed). The owner may claim once the ETH is banked AND the hand is past
    // FEE_WARMUP (1 hour old), so the clock starts at max(lastEthCreditAt, firstBornAt + FEE_WARMUP); every new credit
    // to the hand (a win, or stream ETH banked by a settle) restarts it. reclaimableAt(id) gives the exact moment.
    uint64 public constant UNCLAIMED_WINDOW = 1 hours;
    // ETH of swap volume that arms one draw (price-INDEPENDENT pacing): every 0.05 ETH traded on the ETH leg arms
    // one draw, so the street keeps moving at any market cap.
    uint256 public constant EAT_UNIT    = 0.05 ether;
    uint8   internal constant MAX_DRAIN   = 4;       // max deferred draws armed/resolved per swap (bounded catch-up)
    // COMMIT->REVEAL delay in WALL-CLOCK SECONDS: the game's round. A Base block is 2s, but the owner keeps the
    // Ethereum pace (2026-10-20): a round of draws settles at least 12 s (about 6 Base blocks) after it was armed,
    // never every block. Arming keeps re-pinning the batch until MAX_DRAIN draws wait, so at most one round of up to
    // four draws settles per 12 s. The seed is still the ARMING block's hash; waiting longer changes nothing.
    uint32  internal constant REVEAL_DELAY    = 12;
    // Armed draws older than this are DROPPED rather than resolved on stale flow. On Base 8 minutes is
    // ~240 blocks, inside the 256-block (~8.5 min at 2s) blockhash window the reveal seed reads from.
    uint32  internal constant EAT_STALE_AFTER = 8 minutes;
    // Launch anti-snipe caps, ON TOP of the token's protected-launch budget: two guards on INCOMING transfers,
    // checked by the token through beforeTokenTransfer. Neither can touch a draw: a draw moves balance RAW through
    // gameMove/gameBurn, never through transfer(), so a hand growing past a cap by WINNING is always allowed.
    //   1) MAX TX: no single incoming transfer (one buy) may exceed this share of supply. Until removeMaxTx(), once.
    uint16  public constant MAX_TX_BPS     = 50;         // 0.5% of supply per single buy/transfer (500 DRAW)
    //   2) MAX WALLET: no wallet may HOLD more than this share of supply. Until removeMaxWallet(), once.
    uint16  public constant MAX_WALLET_BPS = 200;        // 2% of supply (2,000 DRAW)
    // The protection window of the token and the module (ProtectedLaunchTokenV1.PROTECTION_SECONDS): inside it the
    // caps bind every recipient, exclusions included, and neither cap can be removed.
    uint256 internal constant PROTECTION_SECONDS = 300;

    // ---- the kernel (ProtectedNative30HookV1's immutables and swap context) ----
    address public immutable token;
    uint24 public immutable lpFee;
    int24 public immutable tickSpacing;
    uint160 public immutable initialSqrtPriceX96;
    address public immutable initializer;
    uint16 public immutable creatorBuyFeeBps;
    uint16 public immutable creatorSellFeeBps;
    address public immutable module;
    bytes32 public immutable moduleCodeHash;
    uint24 public immutable maxModuleLpFeePips;
    EthereumNativeFeeVaultV3 public immutable feeVault;
    EthereumNativeFeeVaultV3 public immutable openingTaxVault;
    uint24 private activeOpeningTaxPpm;
    address private activeBuyer;
    mapping(address => uint256) public boughtDuringProtection;
    bool public initialized;
    bool private swapActive;
    bytes32 private activeSwap;
    uint256 private expectedNativePoolAmount;

    // ---- the game ----
    uint256 public cumulativeVolume;
    uint256 public nextEatAt = EAT_UNIT;
    uint256 public dishNonce;
    uint64  public pendingEats;     // draws armed (volume crossed) but not yet resolved
    uint64  public eatCommitTs;     // TIMESTAMP the pending draws were armed at (resolve only >= +REVEAL_DELAY)
    uint64  public eatCommitBlock;  // block the draws were armed in (resolve only in a strictly later block)

    // The two launch caps. Each starts ON; each `remove*()` flips it OFF permanently (one-way, never re-armable).
    bool public maxTxOn = true;       // 0.5% per-buy cap    -> removeMaxTx()
    bool public maxWalletOn = true;   // 2% per-wallet cap   -> removeMaxWallet()
    // The treasury (the dev wallet): the normal vault's creator recipient (the 2.5%), and the payee of sweepBounty
    // and reclaimUnclaimed. Excluded from the game (never a hand). Immutable.
    address public immutable treasury;
    // The ONLY address with post-launch power: the two one-way cap switches (removeMaxTx, removeMaxWallet), the
    // bounty lever (sweepBounty, which pays the treasury only), reclaimUnclaimed (treasury only), the one-way
    // excludeFromGame (an address off the street for good) and linkMirror (naming the NFT mirror once). It can NEVER
    // raise or add a fee, move holder funds, mint, pause, touch either fee vault, or change the treasury.
    address public immutable capAdmin;
    QuickdrawRenderer public immutable renderer;      // on-chain SVG, a graph target of its own

    QuickdrawNFT public nft;          // the ERC-721 mirror, named once by capAdmin (linkMirror); optional
    mapping(address => bool) public excludedFromGame; // taken off the street by capAdmin (excludeFromGame): never a hand, never cap-exempt

    // bloodstream egress (pull-only, CEI, guarded, OUTSIDE the PoolManager unlock)
    mapping(address => uint256) public ethEscrow; // wei owed to a recipient whose direct send reverted
    uint256 public ethEscrowTotal;                // sum of ethEscrow, part of bloodReserve (never stranded)
    uint256 private _ethLock = 1;                 // 1=unlocked, 2=locked (cheap non-reentrancy guard)

    event NativeFeesAccrued(
        bytes32 indexed poolId,
        address indexed sender,
        bool isBuy,
        uint256 grossNative,
        uint256 platformFee,
        uint256 creatorFee
    );
    event OpeningTaxAccrued(bytes32 indexed poolId, address indexed sender, uint256 grossNative, uint256 amount);
    event BountySwept(uint256 amount);  // capAdmin moved the whole standing bounty to the treasury (dev wallet)
    event EthReclaimed(uint256 indexed id, address indexed owner, uint256 amount); // won ETH unclaimed past the window -> treasury
    event EthPaid(address indexed to, uint256 amount);     // direct ETH send succeeded
    event EthEscrowed(address indexed to, uint256 amount); // recipient rejected -> pull-escrowed
    event EthEscrowClaimed(address indexed to, uint256 amount);
    event MaxTxRemoved();     // the 0.5% per-buy cap was lifted (one-way)
    event MaxWalletRemoved(); // the 2% wallet cap was lifted (one-way)
    event GameExcluded(address indexed who); // capAdmin took an address off the street for good (excludeFromGame)
    event TreasuryEthSwept(uint256 amount); // swept-bounty / reclaimed ETH paid to the treasury

    // the kernel's errors (OpenZeppelin BaseHook, ProtectedNative30HookV1)
    error NotPoolManager();
    error HookNotImplemented();
    error InvalidConfiguration();
    error UnexpectedPool();
    error UnauthorizedInitializer();
    error UninitializedPool();
    error ReentrantSwap();
    error InvalidSwapContext();
    error PartialFillUnsupported(uint256 expected, uint256 actual);
    error UnsupportedCustomDelta();
    error InvalidModuleResponse();
    error ModuleCodeChanged();
    error InvalidDynamicFeeOverride();
    error NoTrade();
    error BuyerLimitExceeded(address buyer, uint256 attempted, uint256 limit);
    // the game's errors
    error OnlyMirror();
    error OnlyToken();
    error Linked_();
    error Reentrancy();
    error NothingToClaim();
    error HandBound();
    error MaxWallet();
    error MaxTx();
    error NotCapAdmin();
    error CapAlreadyRemoved(); // a launch cap was already lifted (shared by removeMaxTx / removeMaxWallet)
    error ProtectionWindow();  // a cap removal before the protection window is over
    error AlreadyExcluded();   // excludeFromGame on an address that is already off the street for good
    error EthSendFailed();     // a payout (sweepBounty / reclaimUnclaimed / claimEscrow) whose recipient rejected the ETH

    /// `manager`, `config`, `developer`, `router`, `routerCodeHash` and `exemptWallets` are the kernel's arguments
    /// (ProtectedNative30HookV1), with config.creatorFeeRecipient = the treasury and both creator rates = 400 bps.
    /// `developer` is the launch wallet (the initial buyer, exempt from the opening tax); `exemptWallets` are up to
    /// six more wallets exempt from the opening tax ONLY, zero for an unused slot. `capAdmin_` is the ONLY post-launch
    /// privileged address. `renderer_` draws the NFT art. `exclusions` are extra addresses that may hold DRAW
    /// without being a hand (the Base Uniswap infrastructure is baked in below; Programmable's Graph Factory and
    /// 24h Router come in here).
    constructor(
        IPoolManager manager,
        PoolConfig memory config,
        address developer,
        address router,
        bytes32 routerCodeHash,
        address[6] memory exemptWallets,
        address capAdmin_,
        QuickdrawRenderer renderer_,
        address[] memory exclusions
    ) {
        // OpenZeppelin BaseHook's constructor: the pool manager, and the mined address must carry exactly these flags
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        CHAIN_ID = block.chainid;
        CANONICAL_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b; // Uniswap v4 PoolManager, Base
        if (
            block.chainid != 8453 || address(manager) != CANONICAL_POOL_MANAGER || address(manager).code.length == 0
                || config.lpFee != 0 || config.tickSpacing != 60 || config.module != address(0)
                || config.creatorBuyFeeBps != CREATOR_FEE_BPS || config.creatorSellFeeBps != CREATOR_FEE_BPS
                || config.token == address(0) || config.initializer == address(0)
                || config.creatorFeeRecipient == address(0) || config.initialSqrtPriceX96 == 0
                || config.maxModuleLpFeePips != 0 || capAdmin_ == address(0)
        ) revert InvalidConfiguration();
        config.lpFee.getInitialLPFee();
        if (
            IQuickdrawToken(config.token).initializer() != config.initializer
                || IQuickdrawToken(config.token).poolManager() != address(manager)
        ) revert InvalidConfiguration();
        token = config.token;
        lpFee = config.lpFee;
        tickSpacing = config.tickSpacing;
        initialSqrtPriceX96 = config.initialSqrtPriceX96;
        initializer = config.initializer;
        creatorBuyFeeBps = config.creatorBuyFeeBps;
        creatorSellFeeBps = config.creatorSellFeeBps;
        treasury = config.creatorFeeRecipient;
        capAdmin = capAdmin_;
        renderer = renderer_;
        // the token learns its game here, while this contract is still in construction (QuickdrawToken.bindGame);
        // a call, not a CREATE, so the three children below keep CREATE nonces 1, 2 and 3
        IQuickdrawToken(config.token).bindGame();
        // the normal fee vault as CREATE child 1, as in ProtectedNative30HookV1
        feeVault = new EthereumNativeFeeVaultV3(manager, config.creatorFeeRecipient);
        BaseLaunchProtectionModuleV1 protection = new BaseLaunchProtectionModuleV1(
            address(this),
            ProtectedLaunchTokenV1(config.token),
            developer,
            router,
            routerCodeHash,
            config.creatorBuyFeeBps,
            exemptWallets
        );
        module = address(protection);
        moduleCodeHash = address(protection).codehash;
        maxModuleLpFeePips = 0;
        openingTaxVault = new EthereumNativeFeeVaultV3(manager, PLATFORM_RECIPIENT);

        isExcluded[address(this)] = true;
        isExcluded[address(manager)] = true;
        isExcluded[DEAD] = true;
        isExcluded[address(0)] = true;
        isExcluded[PERMIT2] = true;
        isExcluded[config.token] = true;
        isExcluded[config.initializer] = true;          // holds the supply, then the rounding dust: never a hand
        isExcluded[config.creatorFeeRecipient] = true;  // the treasury, never plays the game
        isExcluded[address(feeVault)] = true;
        isExcluded[address(protection)] = true;
        isExcluded[address(openingTaxVault)] = true;
        isExcluded[UNIVERSAL_ROUTER] = true;
        isExcluded[UNIVERSAL_ROUTER_2] = true;
        isExcluded[POSITION_MANAGER] = true;
        isExcluded[router] = true;                      // Programmable's trading router (the module pins it)
        for (uint256 i = 0; i < exclusions.length; i++) isExcluded[exclusions[i]] = true;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), lpFee, tickSpacing, IHooks(address(this)));
    }

    /*//////////////////// the kernel's fee quotes (ProtectedNative30HookV1) ////////////////////*/

    /// @notice Quote gross native trade value and fixed-recipient fee allocations, all denominated in wei.
    /// @dev Gross includes platform and creator hook fees. Core LP fees already affect the core trade price.
    ///      Creator rates cannot reduce platform's independent ceil(gross * 30 / 10000) allocation. The creator fee
    ///      is the project's 4.0%: the dev's 2.5 points (normal vault) and the game's 1.5 points (bounty).
    function quoteFees(uint256 amount, bool amountIsNet, bool isBuy)
        public
        view
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee)
    {
        uint256 totalBps = PLATFORM_FEE_BPS + uint256(isBuy ? creatorBuyFeeBps : creatorSellFeeBps);
        gross =
            amountIsNet ? Math.mulDiv(amount, FEE_DENOMINATOR, FEE_DENOMINATOR - totalBps, Math.Rounding.Ceil) : amount;
        uint256 totalFee =
            amountIsNet ? gross - amount : Math.mulDiv(gross, totalBps, FEE_DENOMINATOR, Math.Rounding.Ceil);
        platformFee = Math.mulDiv(gross, PLATFORM_FEE_BPS, FEE_DENOMINATOR, Math.Rounding.Ceil);
        creatorFee = totalFee - platformFee;
    }

    function previewTradeFees(uint256 amount, bool amountIsNet, bool isBuy, address buyer)
        external
        view
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 openingTax)
    {
        uint24 taxPpm = isBuy ? BaseLaunchProtectionModuleV1(module).additionalTaxPpmForBuyer(buyer) : 0;
        return _quoteTradeFees(amount, amountIsNet, isBuy, taxPpm);
    }

    /// The split of a trade's creator fee: the game's bounty share (rounded down) and the dev's share (the rest).
    function creatorFeeSplit(uint256 creatorFee) internal pure returns (uint256 devFee, uint256 bountyFee) {
        bountyFee = creatorFee * BOUNTY_FEE_BPS / CREATOR_FEE_BPS;
        devFee = creatorFee - bountyFee;
    }

    function _quoteTradeFees(uint256 amount, bool amountIsNet, bool isBuy, uint24 taxPpm)
        private
        view
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 openingTax)
    {
        uint256 normalPpm = (PLATFORM_FEE_BPS + uint256(isBuy ? creatorBuyFeeBps : creatorSellFeeBps)) * 100;
        uint256 totalPpm = normalPpm + taxPpm;
        if (totalPpm >= 1_000_000) revert InvalidConfiguration();
        gross = amountIsNet ? Math.mulDiv(amount, 1_000_000, 1_000_000 - totalPpm, Math.Rounding.Ceil) : amount;
        uint256 totalFee = amountIsNet ? gross - amount : Math.mulDiv(gross, totalPpm, 1_000_000, Math.Rounding.Ceil);
        uint256 normalFee = Math.mulDiv(gross, normalPpm, 1_000_000, Math.Rounding.Ceil);
        platformFee = Math.mulDiv(gross, PLATFORM_FEE_BPS, FEE_DENOMINATOR, Math.Rounding.Ceil);
        creatorFee = normalFee - platformFee;
        openingTax = totalFee - normalFee;
    }

    /*//////////////////// v4 hook callbacks: the kernel ////////////////////*/

    // The PoolManager calls only the five callbacks whose flags the mined address carries (0x20CC): beforeInitialize,
    // beforeSwap (+delta) and afterSwap (+delta). The entry points are OpenZeppelin BaseHook's (onlyPoolManager, then
    // the internal callback); the other seven revert, as BaseHook's do.

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeInitialize(sender, key, sqrtPriceX96);
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(sender, key, params, hookData);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) { revert HookNotImplemented(); }
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert HookNotImplemented(); }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 price) internal returns (bytes4) {
        _requirePool(key);
        if (initialized || sender != initializer || price != initialSqrtPriceX96) revert UnauthorizedInitializer();
        initialized = true;
        return IHooks.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        internal
        returns (bytes4, BeforeSwapDelta, uint24 overrideFee)
    {
        _requirePool(key);
        if (!initialized) revert UninitializedPool();
        if (swapActive) revert ReentrantSwap();
        if (params.amountSpecified == 0) revert NoTrade();
        swapActive = true;
        activeSwap = keccak256(abi.encode(sender, key, params, data));
        overrideFee = _beforeModule(sender, key, params, data);
        if (params.zeroForOne && block.timestamp < IQuickdrawToken(token).startedAt() + PROTECTION_SECONDS) {
            activeBuyer = BaseLaunchProtectionModuleV1(module).protectedBuyer(sender);
        }
        activeOpeningTaxPpm = params.zeroForOne ? BaseLaunchProtectionModuleV1(module).openingTaxPpmForSender(sender) : 0;
        bool nativeIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        if (!nativeIsSpecified) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overrideFee);
        uint256 nativeAmount = _absolute(params.amountSpecified);
        (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 openingTax) =
            _quoteTradeFees(nativeAmount, params.amountSpecified > 0, params.zeroForOne, activeOpeningTaxPpm);
        uint256 total = platformFee + creatorFee + openingTax;
        if (params.amountSpecified < 0 && total >= nativeAmount) revert NoTrade();
        expectedNativePoolAmount = params.amountSpecified > 0 ? gross : nativeAmount - total;
        if (expectedNativePoolAmount == 0) revert NoTrade();
        _accrue(sender, key, params.zeroForOne, gross, platformFee, creatorFee, openingTax);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_int128(total), 0), overrideFee);
    }

    /// The kernel's afterSwap, then the game: the pool's native amount is the volume that arms draws (both
    /// directions, price-independent), and draws armed in an earlier block resolve first.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) internal returns (bytes4, int128) {
        _requirePool(key);
        if (!swapActive || activeSwap != keccak256(abi.encode(sender, key, params, data))) revert InvalidSwapContext();
        uint256 nativeAmount = _absolute(int256(delta.amount0()));
        if (nativeAmount == 0 || delta.amount1() == 0) revert NoTrade();
        bool nativeIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        uint256 total;
        if (nativeIsSpecified) {
            if (nativeAmount != expectedNativePoolAmount) {
                revert PartialFillUnsupported(expectedNativePoolAmount, nativeAmount);
            }
        } else {
            (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 openingTax) =
                _quoteTradeFees(nativeAmount, params.amountSpecified > 0, params.zeroForOne, activeOpeningTaxPpm);
            total = platformFee + creatorFee + openingTax;
            if (params.amountSpecified < 0 && total >= nativeAmount) revert NoTrade();
            _accrue(sender, key, params.zeroForOne, gross, platformFee, creatorFee, openingTax);
        }
        if (activeBuyer != address(0)) {
            if (delta.amount1() <= 0) revert NoTrade();
            uint256 bought = boughtDuringProtection[activeBuyer] + uint256(uint128(delta.amount1()));
            uint256 limit = SUPPLY * MAX_WALLET_BPS / BPS; // == QuickdrawToken.walletTokenLimit(): 2% of the fixed supply
            if (bought > limit) revert BuyerLimitExceeded(activeBuyer, bought, limit);
            boughtDuringProtection[activeBuyer] = bought;
            activeBuyer = address(0);
        }
        _afterModule(sender, key, params, delta, data);
        expectedNativePoolAmount = 0;
        activeSwap = bytes32(0);
        activeOpeningTaxPpm = 0;
        swapActive = false;
        _processSwap(nativeAmount);
        return (IHooks.afterSwap.selector, _int128(total));
    }

    function _beforeModule(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        private
        view
        returns (uint24 overrideFee)
    {
        if (module == address(0)) return 0;
        _requireModuleCode();
        (bytes4 selector, BeforeSwapDelta customDelta, uint24 fee) =
            IProtectedNativeFeeModuleV1(module).beforeSwap(sender, key, params, data);
        if (selector != IProtectedNativeFeeModuleV1.beforeSwap.selector) revert InvalidModuleResponse();
        if (BeforeSwapDelta.unwrap(customDelta) != 0) revert UnsupportedCustomDelta();
        // lpFee is fixed at 0 (static) and maxModuleLpFeePips at 0 by the constructor, so the kernel's dynamic-fee
        // branch (!lpFee.isDynamicFee() -> revert) rejects every nonzero override: the same rule, stated directly
        if (fee != 0) revert InvalidDynamicFeeOverride();
        return fee;
    }

    function _afterModule(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) private view {
        if (module == address(0)) return;
        _requireModuleCode();
        (bytes4 selector, int128 customDelta) =
            IProtectedNativeFeeModuleV1(module).afterSwap(sender, key, params, delta, data);
        if (selector != IProtectedNativeFeeModuleV1.afterSwap.selector) revert InvalidModuleResponse();
        if (customDelta != 0) revert UnsupportedCustomDelta();
    }

    function _requireModuleCode() private view {
        if (module.codehash != moduleCodeHash) revert ModuleCodeChanged();
    }

    function _requirePool(PoolKey calldata key) private view {
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != token || key.fee != lpFee
                || key.tickSpacing != tickSpacing || address(key.hooks) != address(this)
        ) revert UnexpectedPool();
    }

    /// The kernel's accrual, with the creator fee split: the platform fee and the dev's share funded as native
    /// ERC-6909 claims of the normal vault and recorded on its two ledgers; the opening tax funded and recorded in the
    /// opening-tax vault (platform ledger only); the game's bounty share taken here as native ETH into bountyPool.
    function _accrue(
        address sender,
        PoolKey calldata key,
        bool isBuy,
        uint256 gross,
        uint256 platformFee,
        uint256 creatorFee,
        uint256 openingTax
    ) private {
        (uint256 devFee, uint256 bountyFee) = creatorFeeSplit(creatorFee);
        uint256 vaulted = platformFee + devFee;
        _int128(vaulted);
        poolManager.mint(address(feeVault), 0, vaulted);
        feeVault.recordFees(platformFee, devFee);
        emit NativeFeesAccrued(keccak256(abi.encode(key)), sender, isBuy, gross, platformFee, devFee);
        if (bountyFee != 0) {
            poolManager.take(Currency.wrap(address(0)), address(this), bountyFee);
            _intakeBlood(bountyFee);
        }
        if (openingTax != 0) {
            _int128(openingTax);
            poolManager.mint(address(openingTaxVault), 0, openingTax);
            openingTaxVault.recordFees(openingTax, 0);
            emit OpeningTaxAccrued(keccak256(abi.encode(key)), sender, gross, openingTax);
        }
    }

    /// SafeCast's toInt256().toInt128(): the amount as an int128, reverting when it does not fit.
    function _int128(uint256 amount) private pure returns (int128) {
        if (amount > uint256(uint128(type(int128).max))) revert InvalidConfiguration();
        return int128(int256(amount));
    }

    function _absolute(int256 amount) private pure returns (uint256) {
        if (amount == type(int256).min) revert InvalidConfiguration();
        return uint256(amount < 0 ? -amount : amount);
    }

    /*//////////////////// modifiers ////////////////////*/

    modifier onlyNFT() {
        if (msg.sender != address(nft)) revert OnlyMirror();
        _;
    }

    modifier onlyToken() {
        if (msg.sender != token) revert OnlyToken();
        _;
    }

    /// Cheap non-reentrancy guard for the ETH egress paths (claimEth / escrow / spore pull / sweeps).
    modifier nonReentrant() {
        if (_ethLock == 2) revert Reentrancy();
        _ethLock = 2;
        _;
        _ethLock = 1;
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

    /// Called by the token BEFORE every transfer / transferFrom moves a balance, after the token's own protected
    /// budget passed. A v4 buy lands as a transfer FROM the PoolManager TO the buyer, so checking the `to` side
    /// covers direct swaps, routers and the initializer's initial buy. The pool side (`to` = the PoolManager: sells,
    /// the seeding) and this hook are never limited, so SELLS are never restricted.
    ///   - MAX TX     : one transfer may not exceed MAX_TX_BPS of supply. Lives until removeMaxTx() (one-way).
    ///   - MAX WALLET : a wallet may not end up holding more than MAX_WALLET_BPS of supply. Lives until
    ///                  removeMaxWallet() (one-way).
    /// Inside the protection window both bind every recipient; after it, excluded infrastructure is exempt.
    /// Game moves (gameMove / gameBurn) never come through here, so draws and decay are never limited.
    function beforeTokenTransfer(address, address to, uint256 amount) external view onlyToken {
        uint256 started = IQuickdrawToken(token).startedAt();
        if (started == 0 || to == address(poolManager) || to == address(this)) return; // the seeding, or the pool side
        // after the window, excluded infrastructure is exempt; an address excluded from the GAME (excludeFromGame) is not
        if (block.timestamp >= started + PROTECTION_SECONDS && isExcluded[to] && !excludedFromGame[to]) return;
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

    /// Take `who` off the street for good: it stops being a hand and can never become one again (for contracts that
    /// will hold DRAW in escrow, such as a 1v1 betting contract). capAdmin only, ONE-WAY, and only after the
    /// protection window. A live hand is husked at once under the husk rules (its mass leaves the board, its banked
    /// and pending stream ETH is forfeited to the survivors, its spores stay pullable). It bypasses no transfer limit:
    /// the max-tx and max-wallet caps keep binding it until capAdmin removes them.
    function excludeFromGame(address who) external {
        if (msg.sender != capAdmin) revert NotCapAdmin();
        _afterWindow();
        if (isExcluded[who]) revert AlreadyExcluded();
        isExcluded[who] = true;
        excludedFromGame[who] = true;
        uint256 id = _idOf(who);
        if (hands[id].alive) _husk(id, who);
        emit GameExcluded(who);
    }

    function _afterWindow() internal view {
        uint256 started = IQuickdrawToken(token).startedAt();
        if (started == 0 || block.timestamp < started + PROTECTION_SECONDS) revert ProtectionWindow();
    }

    /// Move the ENTIRE standing bounty to the treasury (the dev wallet) for a manual buyback. capAdmin only,
    /// guarded, OUTSIDE any PoolManager unlock. The wei leaves the bloodstream through ethOut, so
    /// bloodReserve() (= ethIn - ethOut + escrow) stays exact; a treasury that rejects the ETH fails this call only
    /// (EthSendFailed). Holder-claimable ETH
    /// (handEth, bloodClaimable, escrow) and both fee vaults are out of its reach. A draw settled right after a
    /// sweep pays a 0 prize and still resolves.
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
    /// bloodstream through ethOut (bloodReserve() stays exact) and is paid to the treasury like a swept bounty.
    /// It never touches DRAW balances, spores (bloodClaimable),
    /// escrow, the fee vaults or the bountyPool, and never runs decay. The owner's claimEth works exactly as before
    /// until the moment of a reclaim; after it there is nothing to claim until the hand wins again.
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

    /// Hand swept-bounty / reclaimed ETH straight to the treasury, in ETH, never in DRAW. Only capAdmin's own
    /// sweepBounty / reclaimUnclaimed pay here, outside any PoolManager unlock and after their state is written
    /// (CEI, guarded), so a treasury that rejects the ETH only fails that call (EthSendFailed) and nothing is lost.
    /// (No swap pays the treasury any more: its 2.5% accrues in the normal fee vault, claimed by claimCreator().)
    function _payTreasuryEth(uint256 amount) internal {
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert EthSendFailed();
        emit TreasuryEthSwept(amount);
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

    /// The street's claim (warm only): decays the hand, banks its pending ETH and returns 0, because there is no
    /// token-side fee to claim in DRAW. Kept for the street's selector; won ETH is taken with claimEth().
    function claim() external returns (uint256 fees) {
        fees = _claim(_idOf(msg.sender), msg.sender);
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
        if (!ok) revert EthSendFailed();
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
    /// the ARMING block (on Base, the sequencer) keeps one shot at biasing a draw armed inside it (the standard floor
    /// for on-chain randomness without a VRF); the seed only randomises SELECTION AMONG bucket occupants, the percentage floor
    /// and KILL_COOLDOWN cap the payoff, and 95% of taken mass is burned.
    ///
    /// BLOCK TIME: a Base block is 2s and REVEAL_DELAY is 12s, so a round settles about 6 blocks after its arming
    /// block. The block gate is what guarantees `blockhash(eatCommitBlock)` is readable at all.
    function _resolveEats() internal {
        uint256 pe = pendingEats;
        if (pe == 0) return;
        if (block.timestamp < uint256(eatCommitTs) + REVEAL_DELAY) return;
        if (block.number <= uint256(eatCommitBlock)) return;
        pendingEats = 0;
        if (liveMass == 0) return; // nothing to draw on; drop the armed draws
        // staleness: after a long idle gap, drop the armed draws instead of resolving on stale flow.
        if (block.timestamp > uint256(eatCommitTs) + EAT_STALE_AFTER) return;
        // seal := hash of the block the draws were armed in. EAT_STALE_AFTER (8 min ~= 240 Base blocks) keeps this
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

    /*//////////////////// QUICKDRAW-1 detection surface ////////////////////*/

    /// ERC-165: advertises ERC-165 itself and the QUICKDRAW-1 interface id.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == QUICKDRAW_INTERFACE_ID; // ERC-165 || QUICKDRAW-1
    }

    /// The ETH the bloodstream owns: the un-paid-out wei (`ethIn - ethOut`: banked wins + parked bounty +
    /// spores owed) plus the pull-escrow bucket; address(this).balance always covers it.
    /// The fee vaults hold their own ERC-6909 claims on the PoolManager, never ETH of this hook.
    function bloodReserve() public view override returns (uint256) {
        return (ethIn - ethOut) + ethEscrowTotal;
    }

    receive() external payable {}
}
