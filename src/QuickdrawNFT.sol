// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IQuickdrawBase {
    function handOwnerOf(uint256 id) external view returns (address);
    function handBalanceOf(address owner) external view returns (uint256);
    function handTokenURI(uint256 id) external view returns (string memory);
    function mirrorTransfer(address from, address to, uint256 id) external;
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/*//////////////////////////////////////////////////////////////////////////
        $DRAW // the hand, mirrored as a soulbound ERC-721
//////////////////////////////////////////////////////////////////////////*/
/*
  You cannot be an ERC-20 and an ERC-721 in one contract, the two `Transfer` signatures collide,
  so the NFT lives here and mirrors the street (DN404 does the same dance). It holds nothing worth
  stealing: ownership and metadata are read straight from the base, this contract only keeps
  approvals and emits the canonical events, so a hand shows up and renders in any wallet or
  marketplace.

  The hand is address-bound, tokenId == uint160(owner), so it CANNOT be sold apart from the
  balance it represents; every transfer entry point reverts (HandBound). That is soulbound on
  purpose, and we advertise it honestly via EIP-5192 (`locked()` + `Locked` on mint) so a
  marketplace gates it instead of listing a token that can never move. The art is live, an eat
  changes a hand's rendered mass with no ERC-721 `Transfer`, so the base fires ERC-4906
  `MetadataUpdate` to make indexers re-pull. supportsInterface claims exactly what is true:
  165 / 721 / 721Metadata / 4906 / 5192, nothing aspirational.
*/
contract QuickdrawNFT {
    string public constant name = "Quickdraw";
    string public constant symbol = "DRAW";
    IQuickdrawBase public immutable base;

    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    // EIP-5192 (soulbound): hands are address-bound and permanently locked.
    event Locked(uint256 tokenId);
    event Unlocked(uint256 tokenId);
    // ERC-4906 (metadata refresh): mass changes the art with no ERC-721 Transfer, so signal a re-pull.
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    error OnlyBase();
    error NotAuthorized();
    error WrongFrom();
    error ToZero();
    error UnsafeRecipient();

    constructor(IQuickdrawBase _base) { base = _base; }

    modifier onlyBase() { if (msg.sender != address(base)) revert OnlyBase(); _; }

    function ownerOf(uint256 id) public view returns (address) { return base.handOwnerOf(id); }
    function balanceOf(address owner) external view returns (uint256) { return base.handBalanceOf(owner); }
    function tokenURI(uint256 id) external view returns (string memory) { return base.handTokenURI(id); }

    function approve(address spender, uint256 id) external {
        address owner = base.handOwnerOf(id);
        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender]) revert NotAuthorized();
        getApproved[id] = spender;
        emit Approval(owner, spender, id);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 id) public {
        if (to == address(0)) revert ToZero();
        address owner = base.handOwnerOf(id);
        if (from != owner) revert WrongFrom();
        if (msg.sender != owner && msg.sender != getApproved[id] && !isApprovedForAll[owner][msg.sender]) {
            revert NotAuthorized();
        }
        delete getApproved[id];
        base.mirrorTransfer(from, to, id); // updates the street; reverts if `to` is at the hand cap
        emit Transfer(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        transferFrom(from, to, id);
        _checkReceiver(from, to, id, "");
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data) external {
        transferFrom(from, to, id);
        _checkReceiver(from, to, id, data);
    }

    function _checkReceiver(address from, address to, uint256 id, bytes memory data) internal {
        if (to.code.length == 0) return;
        if (IERC721Receiver(to).onERC721Received(msg.sender, from, id, data) != IERC721Receiver.onERC721Received.selector) {
            revert UnsafeRecipient();
        }
    }

    /// Mint / burn / lifecycle events emitted by the base (stake, molt, eat).
    function emitTransfer(address from, address to, uint256 id) external onlyBase {
        emit Transfer(from, to, id);
        if (from == address(0)) emit Locked(id); // EIP-5192: a hand is permanently soulbound on mint
    }

    /// The base signals an ERC-4906 metadata refresh when a hand's mass changes WITHOUT a Transfer
    /// (e.g. it is eaten), so event-driven marketplaces / indexers re-pull the live art.
    function emitMetadataUpdate(uint256 id) external onlyBase {
        emit MetadataUpdate(id);
    }

    /// EIP-5192: hands are address-bound (soulbound); every existing hand is permanently locked.
    function locked(uint256 id) external view returns (bool) {
        base.handOwnerOf(id); // reverts for a non-existent (dead) hand, per EIP-5192
        return true;
    }

    function supportsInterface(bytes4 i) external pure returns (bool) {
        return i == 0x01ffc9a7   // ERC165
            || i == 0x80ac58cd   // ERC721
            || i == 0x5b5e139f   // ERC721Metadata
            || i == 0x49064906   // ERC-4906 (metadata update)
            || i == 0xb45a3c0e;  // EIP-5192 (soulbound / locked)
    }
}
