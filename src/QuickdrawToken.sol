// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// The hook, as the token sees it: its own token (the binding check), asked before every transfer (the two launch
/// caps) and told after it (the resync that turns a balance into a hand on the street).
interface IQuickdrawGame {
    function token() external view returns (address);
    function beforeTokenTransfer(address from, address to, uint256 amount) external;
    function afterTokenTransfer(address from, address to) external;
}

/*
  DRAW, the coin. 100,000, minted once to the launch initializer (Programmable's ProtectedNativeInitializerV1),
  which seeds all of it into the pool and locks it there. No owner, no mint after construction, no pause, no fee
  inside the token, no setter of any kind.

  THE LAUNCH PROTECTION SURFACE, with the semantics of Programmable's ProtectedLaunchTokenV1 (the initializer and the
  protection module read it): initializer(), poolManager(), launchSupply(), walletTokenLimit(), startedAt(), start()
  (the initializer only, once), receivedDuringProtection(address), WALLET_LIMIT_BPS 200, PROTECTION_SECONDS 300,
  POLICY_REVISION 2.
    - Before start() only the initializer's seeding moves inventory, and only to the PoolManager.
    - For PROTECTION_SECONDS after start() every recipient except the PoolManager has a CUMULATIVE inflow budget of
      walletTokenLimit (2% of the launch supply, 2,000 DRAW): transfers and pool withdrawals (a buy lands as a
      PoolManager -> buyer transfer) both count; sending out, selling or losing a draw never refills it. A
      self-transfer neither mints nor consumes budget. Nobody else is exempt: the dev wallet, the treasury, every
      tax-exempt wallet and every excluded address carry the same budget.

  THE GAME lives in the hook (`game`). Every transfer asks it first (the max-tx 0.5% / max-wallet 2% caps, on top of
  the budget above) and tells it afterwards, so a buy enrols you and a sell knocks you down with no action on your
  part. The game alone may move or burn balances RAW (draws, decay): no budget, no cap check, no callback (the hook
  reconciles its own state). metadata() is what Programmable's site reads; it is fixed at birth.

  WHY THE GAME IS BOUND, NOT PASSED: the protection module the hook creates needs this token's code, so the token
  exists first and cannot name the hook. bindGame() is accepted exactly once, only before start(), and only from a
  caller that is still in construction (no code yet): the hook calls it from its own constructor, and a hook whose
  binding fails is never deployed. Programmable's Graph Factory deploys the token and the hook in ONE atomic graph
  transaction, so nothing can call in between. start() then checks that the bound game names this token, so the pool
  can never open under any other binding.

  BURN: any holder may burn its own DRAW (burn, as in ProtectedLaunchTokenV1); userBurned counts it, so
  SUPPLY - totalSupply == the game's totalBurned + userBurned.

  Every runtime balance move goes through one internal `_move` and every burn through `_burnFrom`, so the Transfer
  topic is emitted from two places only (it stays a PUSH32 immediate in the runtime; with more emit sites solc's
  constant optimizer parks the hash in the code's data tail, where a linear opcode walk would misread its bytes as
  CALLCODE / CREATE2).
*/
contract QuickdrawToken is ERC20 {
    uint256 public constant SUPPLY = 100_000e18;
    uint256 public constant POLICY_REVISION = 2;
    uint256 public constant WALLET_LIMIT_BPS = 200;
    uint256 public constant PROTECTION_SECONDS = 300;
    address public immutable initializer; // ProtectedNativeInitializerV1: holds the supply until it seeds the pool
    address public immutable poolManager; // Uniswap v4 PoolManager: the settlement side, outside the inflow budget
    uint256 public immutable launchSupply; // SUPPLY
    uint256 public immutable walletTokenLimit; // 2% of launchSupply: the cumulative inflow budget in the window
    uint256 public startedAt; // set once by start(), inside the initializer's atomic launch
    mapping(address => uint256) public receivedDuringProtection;
    address public game; // the QuickdrawHook, bound once from its constructor
    uint256 public userBurned; // DRAW burned by holders themselves through burn() (the game's burns are its totalBurned)

    string private _description;
    string private _website;
    string private _image;
    bytes private _extraData;

    error InvalidConfiguration();
    error NotInitializer();
    error AlreadyStarted();
    error TradingNotStarted();
    error WalletLimitExceeded(address recipient, uint256 attempted, uint256 limit);
    error OnlyGame();
    error GameAlreadyBound();
    error GameNotBound();

    event GameBound(address indexed game);

    constructor(
        address initializer_,
        address manager_,
        string memory description_,
        string memory website_,
        string memory image_,
        bytes memory extraData_
    ) ERC20("Quickdraw", "DRAW", 18) {
        if (initializer_ == address(0) || manager_.code.length == 0 || initializer_ == manager_) revert InvalidConfiguration();
        initializer = initializer_;
        poolManager = manager_;
        launchSupply = SUPPLY;
        walletTokenLimit = SUPPLY * WALLET_LIMIT_BPS / 10_000;
        _description = description_;
        _website = website_;
        _image = image_;
        _extraData = extraData_;
        _mint(initializer_, SUPPLY); // solmate's _mint moves no balance through transfer(): the game is not asked
    }

    function metadata() external view returns (string memory description, string memory website, string memory image, bytes memory extraData) {
        return (_description, _website, _image, _extraData);
    }

    /// One-time: the hook names itself from its constructor (see the header). Never after start().
    function bindGame() external {
        if (game != address(0)) revert GameAlreadyBound();
        if (startedAt != 0 || msg.sender.code.length != 0) revert InvalidConfiguration();
        game = msg.sender;
        emit GameBound(msg.sender);
    }

    /// The initializer starts the protection clock once, inside its atomic launch, after seeding the pool.
    function start() external {
        if (msg.sender != initializer) revert NotInitializer();
        if (startedAt != 0) revert AlreadyStarted();
        if (block.timestamp == 0) revert InvalidConfiguration();
        address g = game;
        if (g == address(0) || IQuickdrawGame(g).token() != address(this)) revert GameNotBound();
        startedAt = block.timestamp;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _protect(msg.sender, to, amount);
        address g = game;
        IQuickdrawGame(g).beforeTokenTransfer(msg.sender, to, amount);
        _move(msg.sender, to, amount);
        IQuickdrawGame(g).afterTokenTransfer(msg.sender, to);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _protect(from, to, amount);
        address g = game;
        IQuickdrawGame(g).beforeTokenTransfer(from, to, amount);
        uint256 allowed = allowance[from][msg.sender]; // saves gas for limited approvals, as in solmate
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        IQuickdrawGame(g).afterTokenTransfer(from, to);
        return true;
    }

    /// RAW move for a draw (loser -> winner). Game only; no budget, no cap check, no callback: the hook resyncs itself.
    function gameMove(address from, address to, uint256 amount) external {
        if (msg.sender != game) revert OnlyGame();
        _move(from, to, amount);
    }

    /// RAW burn for a draw (95% of what a loser gives up) or idle decay. Game only; shrinks totalSupply. The game
    /// counts these in its own totalBurned.
    function gameBurn(address from, uint256 amount) external {
        if (msg.sender != game) revert OnlyGame();
        _burnFrom(from, amount);
    }

    /// Burn your own DRAW (ProtectedLaunchTokenV1 has the same function): totalSupply shrinks, userBurned counts it,
    /// and your hand resyncs exactly as after a transfer out (it shrinks, or husks under the floor). Burning never
    /// refills the protection budget. So SUPPLY - totalSupply == game.totalBurned() + userBurned, always.
    function burn(uint256 amount) external {
        _burnFrom(msg.sender, amount);
        unchecked { userBurned += amount; } // bounded by SUPPLY
        address g = game;
        if (g != address(0)) IQuickdrawGame(g).afterTokenTransfer(msg.sender, address(0));
    }

    function _burnFrom(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        unchecked { totalSupply -= amount; }
        emit Transfer(from, address(0), amount);
    }

    /// The launch protection, exactly ProtectedLaunchTokenV1._update's rule for an ordinary move.
    function _protect(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0) || amount == 0) return;
        uint256 started = startedAt;
        if (started == 0) {
            // Only the initializer's seed settlement may move inventory before the atomic start.
            if (from != initializer || to != poolManager) revert TradingNotStarted();
        } else if (block.timestamp < started + PROTECTION_SECONDS && to != poolManager) {
            // Self-transfers cannot mint headroom, and do not consume it either.
            if (from != to) {
                uint256 received = receivedDuringProtection[to] + amount;
                if (received > walletTokenLimit) revert WalletLimitExceeded(to, received, walletTokenLimit);
                receivedDuringProtection[to] = received;
            }
        }
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        // cannot overflow: the sum of all balances is capped by totalSupply
        unchecked { balanceOf[to] += amount; }
        emit Transfer(from, to, amount);
    }
}
