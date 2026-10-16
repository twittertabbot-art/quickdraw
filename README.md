# Quickdraw

A duel that lives inside the token. Hold DRAW and your wallet stands on the street. Trading arms a draw, the block
picks two holders of similar size, and the bigger hand shoots first. Most of what the loser drops is burned, and the
winner takes ETH from the bounty.

Website: https://quickdrawprotocol.xyz

## Contracts

| File | Contract | Role |
|---|---|---|
| `src/QuickdrawToken.sol` | QuickdrawToken | the DRAW token, 100,000 supply minted once |
| `src/QuickdrawHook.sol` | QuickdrawHook | the Uniswap v4 hook: fees on the ETH leg, launch caps, the game |
| `src/QuickdrawGame.sol` | QuickdrawGame | the game engine the hook runs: hands, draws, shields, floors |
| `src/QuickdrawLauncher.sol` | QuickdrawLauncher | opens the native ETH / DRAW pool and holds its liquidity forever |
| `src/QuickdrawNFT.sol` | QuickdrawNFT | a soulbound mirror of every hand |
| `src/QuickdrawRenderer.sol` | QuickdrawRenderer | the on-chain token art |

The files under `lib/` are the exact Uniswap v4 and solmate sources the contracts import.

## Launch protection

For the first 300 seconds after launch, every wallet may buy at most 2% of the supply and receive at most 2%, counted
cumulatively, and buys must come through an authenticated router. The buy fee opens at 99% and falls linearly to the
normal fee over 30 seconds; the extra goes to Programmable's fixed treasury. The launcher only opens the pool at a
market cap of at least $15,000, checked against the Chainlink ETH/USD feed.

## Build settings

solc 0.8.26, EVM cancun, optimizer 200 runs, via-IR, no metadata hash, no CBOR metadata. Import paths are in
`remappings.txt`.
