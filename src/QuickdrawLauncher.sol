// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
  QuickdrawLauncher: the component of the launch graph that opens the pool, fills it and makes the first buy.

  Programmable's Graph Factory deploys the five contracts of the graph through CREATE2, every address known in
  advance: this launcher (depends on nothing), the renderer (depends on nothing), the hook (names the launcher and
  the renderer, at an address mined to carry exactly its five permission bits), the token (mints the whole supply
  to the launcher and names the hook as its game), the NFT mirror (names the hook). Then the factory calls
  initializeGraph(token, hook) here, forwarding the ETH of the launch transaction. This contract tells the hook
  its token (hook.link), opens the native ETH / DRAW pool at INITIAL_TICK (LP fee 0, tick spacing 60), puts the
  full supply on the DRAW side of it in a position OWNED BY THIS CONTRACT, and, when the graph was built with an
  initial buy, buys exactly INITIAL_BUY_TOKENS for BUYER with the ETH it received, refunding what the buy did not
  use. There is no function that removes the position: the liquidity can never leave. Rounding dust stays here.
  The launcher is excluded from the game (baked into the hook), so the dust is never a hand on the street.

  The initial buy lands on BUYER through the token's transfer path, so the hook's launch caps apply to it like to
  any buyer: it can never exceed 0.5% of supply. The same contract serves a direct launch (tests, or a launch
  without Programmable): whoever is INITIALIZER calls initializeGraph() after deploying the token and the hook.
*/
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {QuickdrawToken} from "./QuickdrawToken.sol";

interface IQuickdrawHookLink {
    function link(address token) external;
}

contract QuickdrawLauncher is IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    int24 public constant TICK_SPACING = 60;
    uint24 public constant LP_FEE = 0;
    uint256 internal constant SUPPLY = 100_000e18; // QuickdrawToken.SUPPLY
    /// Exactly the five permission bits QuickdrawHook implements; the hook's address must carry these and no other.
    uint160 public constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    IPoolManager public immutable poolManager;
    address public immutable INITIALIZER; // Programmable's Graph Factory (or the deployer in a direct launch)
    int24 public immutable INITIAL_TICK; // multiple of 60: the start price (currency1 = DRAW per ETH)
    address public immutable BUYER; // the launch wallet: receives the initial buy and the refund
    uint256 public immutable INITIAL_BUY_TOKENS; // exact DRAW of the initial buy; 0 = no initial buy

    address public token;
    address public hook;
    PoolKey internal _key;
    uint256 public dust; // supply that rounding kept out of the position; stays here for ever
    bool public launched;

    event Launched(address indexed token, address indexed hook, bytes32 indexed poolId, int24 initialTick, uint256 liquidity, uint256 dust);
    event InitialBuy(address indexed buyer, uint256 tokens, uint256 ethPaid, uint256 ethRefunded);

    error OnlyInitializer();
    error Once();
    error OnlyPoolManager();
    error BadTick();
    error HookAddressFlags(address hook);
    error NoSupply();
    error NotDeployed(address what);
    error NoBuyer();
    error BuyValue();
    error BuyShape();
    error RefundFailed();

    constructor(address poolManager_, address initializer, int24 initialTick, address buyer, uint256 initialBuyTokens) {
        if (initialTick % TICK_SPACING != 0 || initialTick <= TickMath.minUsableTick(TICK_SPACING) || initialTick >= TickMath.maxUsableTick(TICK_SPACING)) revert BadTick();
        if (initialBuyTokens != 0 && buyer == address(0)) revert NoBuyer();
        if (initialBuyTokens >= SUPPLY) revert BuyValue();
        poolManager = IPoolManager(poolManager_);
        INITIALIZER = initializer;
        INITIAL_TICK = initialTick;
        BUYER = buyer;
        INITIAL_BUY_TOKENS = initialBuyTokens;
    }

    /// True when the address carries exactly our five hook flags (the only callbacks the hook implements).
    function hasHookFlags(address h) public pure returns (bool) {
        return (uint160(h) & Hooks.ALL_HOOK_MASK) == HOOK_FLAGS;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function poolId() external view returns (bytes32) {
        return PoolId.unwrap(_key.toId());
    }

    /// Called once by the initializer after the token and the hook exist. Links the token into the hook, opens the
    /// pool, fills it, makes the initial buy with the ETH it was sent (all of it is the budget; the rest goes back
    /// to BUYER).
    function initializeGraph(address token_, address hook_) external payable {
        if (msg.sender != INITIALIZER) revert OnlyInitializer();
        if (launched) revert Once();
        launched = true;
        if (token_.code.length == 0) revert NotDeployed(token_);
        if (hook_.code.length == 0) revert NotDeployed(hook_);
        if (!hasHookFlags(hook_)) revert HookAddressFlags(hook_);
        if (QuickdrawToken(token_).balanceOf(address(this)) == 0) revert NoSupply();
        if ((INITIAL_BUY_TOKENS == 0) != (msg.value == 0)) revert BuyValue();
        token = token_;
        hook = hook_;
        IQuickdrawHookLink(hook_).link(token_); // the hook learns its token here (this launcher is its deployer)
        // native ETH is always currency0
        _key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(token_), fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(hook_)});

        poolManager.initialize(_key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        bytes memory out = poolManager.unlock(abi.encode(msg.value));
        (uint256 liquidity, uint256 paid) = abi.decode(out, (uint256, uint256));
        dust = QuickdrawToken(token_).balanceOf(address(this));
        if (msg.value != 0) {
            uint256 refund = address(this).balance;
            if (refund != 0) {
                (bool ok,) = BUYER.call{value: refund}("");
                if (!ok) revert RefundFailed();
            }
            emit InitialBuy(BUYER, INITIAL_BUY_TOKENS, paid, refund);
        }
        emit Launched(token_, hook_, PoolId.unwrap(_key.toId()), INITIAL_TICK, liquidity, dust);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        uint256 value = abi.decode(data, (uint256));
        uint256 supply = QuickdrawToken(token).balanceOf(address(this));
        // DRAW is currency1: its liquidity sits below the price, from the bottom of the range up to the start tick
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(INITIAL_TICK), supply);
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            _key, ModifyLiquidityParams({tickLower: tickLower, tickUpper: INITIAL_TICK, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)}), ""
        );
        // the ETH side must be zero (the price sits exactly at the range's edge); pay the DRAW the position needs
        require(d.amount0() == 0 && d.amount1() < 0, "launch: position shape");
        uint256 pay = uint256(uint128(-d.amount1()));
        poolManager.sync(_key.currency1);
        QuickdrawToken(token).transfer(address(poolManager), pay);
        poolManager.settle();

        uint256 paid;
        if (value != 0) {
            // the initial buy: exactly INITIAL_BUY_TOKENS for BUYER. The hook takes its ETH fee on the leg; the
            // DRAW reaches BUYER through the token's transfer path, so the launch caps apply to it like to anyone.
            BalanceDelta s = poolManager.swap(
                _key, SwapParams({zeroForOne: true, amountSpecified: int256(INITIAL_BUY_TOKENS), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), ""
            );
            if (s.amount0() >= 0 || s.amount1() <= 0 || uint256(uint128(s.amount1())) != INITIAL_BUY_TOKENS) revert BuyShape();
            paid = uint256(uint128(-s.amount0()));
            if (paid > value) revert BuyValue();
            poolManager.settle{value: paid}();
            poolManager.take(_key.currency1, BUYER, INITIAL_BUY_TOKENS);
        }
        return abi.encode(uint256(liquidity), paid);
    }
}
