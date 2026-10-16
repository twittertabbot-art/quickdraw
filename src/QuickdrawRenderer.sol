// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////////////////
        $DRAW // the art is the state, drawn on-chain, no IPFS
//////////////////////////////////////////////////////////////////////////*/
/*
  Pure (id, mass, kills) -> a base64 JSON data-URI whose image is an SVG assembled in Solidity.
  Radius tracks sqrt(mass) so area scales with mass (the agar.io read), hue is a deterministic
  identity off the id, the glow steps up with the mass tier (titans actually glow), and kills
  ring the hand as pips. Nothing is pinned anywhere: the street-cam, wallets, and OpenSea all draw
  the same live picture from chain state, so if every front-end vanishes the hands still render.
*/
contract QuickdrawRenderer {
    bytes internal constant B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function tokenURI(uint256 id, uint256 mass, uint256 kills) external pure returns (string memory) {
        string memory svg = _svg(id, mass, kills);
        string memory json = string(abi.encodePacked(
            '{"name":"Quickdraw #', _u(id),
            '","description":"A hand on the Quickdraw street. Stack ', _u(mass / 1e18),
            ' DRAW, ', _u(kills), ' kills. Survival of the richest.",',
            '"attributes":[{"trait_type":"Mass","value":', _u(mass / 1e18),
            '},{"trait_type":"Kills","value":', _u(kills),
            '},{"trait_type":"Tier","value":', _u(_tier(mass)),
            '}],"image":"data:image/svg+xml;base64,', _b64(bytes(svg)), '"}'
        ));
        return string(abi.encodePacked("data:application/json;base64,", _b64(bytes(json))));
    }

    function _svg(uint256 id, uint256 mass, uint256 kills) internal pure returns (string memory) {
        uint256 r = _radius(mass);                 // 14..108 in a 240x240 box
        uint256 hue = uint256(keccak256(abi.encode(id))) % 360;
        uint256 glow = 2 + _tier(mass);            // titans glow brighter
        string memory h = _u(hue);
        string memory pips = _killPips(kills, hue);
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="240" height="240" viewBox="0 0 240 240">',
            '<rect width="240" height="240" fill="#07090c"/>',
            '<defs><radialGradient id="g"><stop offset="0%" stop-color="hsl(', h, ',90%,72%)"/>',
            '<stop offset="70%" stop-color="hsl(', h, ',85%,52%)"/>',
            '<stop offset="100%" stop-color="hsl(', h, ',80%,40%)"/></radialGradient>',
            '<filter id="f"><feGaussianBlur stdDeviation="', _u(glow), '"/></filter></defs>',
            '<circle cx="120" cy="120" r="', _u(r), '" fill="hsl(', h, ',85%,55%)" filter="url(#f)" opacity="0.55"/>',
            '<circle cx="120" cy="120" r="', _u(r), '" fill="url(#g)"/>',
            '<circle cx="120" cy="120" r="', _u(r), '" fill="none" stroke="hsl(', h, ',95%,80%)" stroke-width="1.5" opacity="0.8"/>',
            pips, '</svg>'
        ));
    }

    function _killPips(uint256 kills, uint256 hue) internal pure returns (string memory s) {
        uint256 n = kills > 12 ? 12 : kills;
        string memory h = _u(hue);
        for (uint256 i = 0; i < n; i++) {
            // ring of small dots; cheap fixed-angle placement
            uint256 ang = (i * 360) / 12;
            (int256 dx, int256 dy) = _ring(ang);
            s = string(abi.encodePacked(
                s, '<circle cx="', _i(120 + dx), '" cy="', _i(120 + dy),
                '" r="3" fill="hsl(', h, ',95%,85%)"/>'
            ));
        }
    }

    // unit ring position scaled to radius ~116, 12 fixed angles
    function _ring(uint256 ang) internal pure returns (int256 dx, int256 dy) {
        int16[12] memory cs = [int16(116),100,58,0,-58,-100,-116,-100,-58,0,58,100];
        int16[12] memory sn = [int16(0),58,100,116,100,58,0,-58,-100,-116,-100,-58];
        uint256 k = (ang / 30) % 12;
        return (cs[k], sn[k]);
    }

    function _radius(uint256 mass) internal pure returns (uint256) {
        uint256 s = _sqrt(mass / 1e18);   // sqrt of mass in whole DRAW
        uint256 r = 14 + s / 6;
        return r > 108 ? 108 : r;
    }

    function _tier(uint256 mass) internal pure returns (uint256 t) {
        uint256 m = mass / 1e18;
        while (m >= 4 && t < 9) { m /= 4; t++; }
    }

    /*//////////////////// tiny utils ////////////////////*/

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2; y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 d; uint256 t = v;
        while (t != 0) { d++; t /= 10; }
        bytes memory b = new bytes(d);
        while (v != 0) { d--; b[d] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }

    function _i(int256 v) internal pure returns (string memory) {
        if (v < 0) return string(abi.encodePacked("-", _u(uint256(-v))));
        return _u(uint256(v));
    }

    function _b64(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        bytes memory table = B64;
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        string memory result = new string(encodedLen + 32);
        assembly {
            mstore(result, encodedLen)
            let tablePtr := add(table, 1)
            let dataPtr := data
            let endPtr := add(dataPtr, mload(data))
            let resultPtr := add(result, 32)
            for {} lt(dataPtr, endPtr) {} {
                dataPtr := add(dataPtr, 3)
                let input := mload(dataPtr)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(18, input), 0x3F)))) resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(12, input), 0x3F)))) resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(6, input), 0x3F)))) resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(input, 0x3F)))) resultPtr := add(resultPtr, 1)
            }
            switch mod(mload(data), 3)
            case 1 { mstore8(sub(resultPtr, 1), 0x3d) mstore8(sub(resultPtr, 2), 0x3d) }
            case 2 { mstore8(sub(resultPtr, 1), 0x3d) }
        }
        return result;
    }
}
