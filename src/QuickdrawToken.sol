// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// The hook, as the token sees it: asked before every transfer (the two launch caps and the exclusions) and told
/// after it (the resync that turns a balance into a hand on the street).
interface IQuickdrawGame {
    function beforeTokenTransfer(address from, address to, uint256 amount) external view;
    function afterTokenTransfer(address from, address to) external;
}

/*
  DRAW, the coin. 100,000, minted once to the launcher, which puts all of it into the pool. No owner, no mint,
  no pause, no fee inside the token, no setter of any kind. The game lives in the hook (`game`, fixed at birth):
  every transfer asks it first (max tx 0.5% / max wallet 2% of supply per recipient, excluded infrastructure
  exempt) and tells it afterwards, so a DEX buy enrols you and a sell knocks you down with no action on your part.
  The game alone may move or burn balances RAW (draws, decay): no cap check, no callback, the hook reconciles
  its own state. metadata() is what Programmable's site reads; it is fixed at birth.

  Every runtime balance move goes through one internal `_move`, so the Transfer topic is emitted from two places
  only (it stays a PUSH32 immediate in the runtime; with five emit sites solc's constant optimizer parks the hash in
  the code's data tail, where a linear opcode walk would misread its bytes as CALLCODE / CREATE2).
*/
contract QuickdrawToken is ERC20 {
    uint256 public constant SUPPLY = 100_000e18;
    address public immutable game; // the QuickdrawHook, predicted before this token exists

    string private _description;
    string private _website;
    string private _image;
    bytes private _extraData;

    error OnlyGame();

    constructor(address to, address game_, string memory description_, string memory website_, string memory image_, bytes memory extraData_)
        ERC20("Quickdraw", "DRAW", 18)
    {
        game = game_;
        _description = description_;
        _website = website_;
        _image = image_;
        _extraData = extraData_;
        _mint(to, SUPPLY); // solmate's _mint moves no balance through transfer(): the game is not asked
    }

    function metadata() external view returns (string memory description, string memory website, string memory image, bytes memory extraData) {
        return (_description, _website, _image, _extraData);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        IQuickdrawGame(game).beforeTokenTransfer(msg.sender, to, amount);
        _move(msg.sender, to, amount);
        IQuickdrawGame(game).afterTokenTransfer(msg.sender, to);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        IQuickdrawGame(game).beforeTokenTransfer(from, to, amount);
        uint256 allowed = allowance[from][msg.sender]; // saves gas for limited approvals, as in solmate
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        IQuickdrawGame(game).afterTokenTransfer(from, to);
        return true;
    }

    /// RAW move for a draw (loser -> winner). Game only; no cap check, no callback: the hook resyncs itself.
    function gameMove(address from, address to, uint256 amount) external {
        if (msg.sender != game) revert OnlyGame();
        _move(from, to, amount);
    }

    /// RAW burn for a draw (95% of what a loser gives up) or idle decay. Game only; shrinks totalSupply.
    function gameBurn(address from, uint256 amount) external {
        if (msg.sender != game) revert OnlyGame();
        balanceOf[from] -= amount;
        unchecked { totalSupply -= amount; }
        emit Transfer(from, address(0), amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        // cannot overflow: the sum of all balances is capped by totalSupply
        unchecked { balanceOf[to] += amount; }
        emit Transfer(from, to, amount);
    }
}
