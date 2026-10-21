// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////////////////
        QUICKDRAW // the game: a wallet balance that is a hand on the street
//////////////////////////////////////////////////////////////////////////*/
/*
  The whole idea of QUICKDRAW-1 is one line: a wallet's DRAW balance IS a hand.
  mass = max(0, balanceOf - floor); no stake, no escrow, no NFT to lock, nothing to opt into. Cross the floor
  and a hand is dealt in; fall to it and the hand husks, the tokens stay, the hand just leaves the street.
  Every balance change in the token re-runs `_resync(addr)`, O(1), and it must NEVER revert for a game
  reason, because a transfer that can revert is a transfer that can be weaponised. The game tracks the token;
  it is never a second ledger that can drift out of sync.

  This contract is deliberately inert: no token transfers, no Uniswap, no ETH custody, so the dangerous part,
  the draw, fuzzes in isolation. `QuickdrawHook` inherits it and wires in the real DRAW moves (`_moveMass` /
  `_burnMass`, the balance read `_holderBalance`) and the v4 swap feed.

  Two structural choices carry everything:
    - O(1), always. Hands sit in power-of-two mass buckets (bucket = msb(mass)); one uint256 bitmap flags the
      non-empty ones, so a near-peer winner/loser pair is a single bit-scan, insert is a push, remove is
      swap-and-pop. No loop ever scales with the holder count. The handId IS uint160(owner): one wallet, one
      hand, keyed by its own address.
    - One MasterChef accumulator, run wei-exact. `accEthPerMass` re-apportions a husk's forfeited won ETH to
      survivors (no fee streams to holders). There is no DRAW twin: there is no token-side fee (holders are
      paid in ETH, never in DRAW), so the always-zero DRAW fee stream was removed (2026-10-17). Flash-staking is dead: `bornAt`
      resets on every (re)activation, claims open only past FEE_WARMUP, and a hand that husks FORFEITS what
      it never claimed to the survivors. Claim before you leave.

  The draw is deflationary, not a robbery: of a loser's eatable mass it burns 95% and hands the winner only
  5%, while the percentage floor caps any loser at 25% of its peak. Nobody is wiped (the floor is
  untouchable) and nobody wins their way to a bag: a draw mostly deflates supply and pays an ETH bounty.
  Solvency has one source of truth, (ethIn, ethOut), asserted on every operation.
*/
abstract contract QuickdrawGame {
    uint256 internal constant BPS = 10_000;
    uint16  internal constant SPORE_BPS  = 0;      // no token spore: an eaten hand keeps only its protected floor
    // A DEFLATIONARY DRAW, not a token grab: 95% of the eaten mass is burned and only
    // 5% moves to the predator, so eating barely creates dump-ammo; the predator's real reward is the ETH
    // bounty (clean profit that never hits the chart). spore 0 / burn 95 / gain 5.
    uint16  internal constant BURN_BPS   = 9500;   // 95% -> burned (deflation); remaining 5% -> predator
    uint16  internal constant RATIO_NUM  = 125;    // predator.mass >= prey.mass * 1.25
    uint16  internal constant RATIO_DEN  = 100;
    // PREY shield: a fresh hand is un-eatable for its first 30 seconds — just long enough that a buy cannot be
    // drawn in the same breath, without making new hands invulnerable while everyone else is in play.
    // (Keyed to firstBornAt, un-resettable -> husk+rebuy cannot refresh it.)
    uint64  internal constant MIN_AGE      = 30 seconds;
    // PREDATOR establishment, deliberately kept MUCH longer than the prey shield. These were one constant
    // until the prey side was shortened; they are split because they do different jobs. This one is not
    // player protection, it is anti-manipulation: without it a brand-new wallet could be funded, sized to sit
    // at the top of a tier, and used as a hunter within seconds. Five minutes of capital exposure makes that
    // expensive. Shortening THIS is what would weaken the un-aimable property, not shortening MIN_AGE.
    uint64  internal constant PRED_MIN_AGE = 5 minutes;
    uint64  internal constant FEE_WARMUP = 1 hours;   // fees/ETH only claimable past this age (anti-flash-stake)
    uint128 internal constant DUST_FLOOR = 1e14;    // 0.0001 DRAW of mass: below this a hand is never prey
    uint256 internal constant ACC_PREC   = 1e30;    // fee-per-mass fixed-point precision
    uint256 internal constant DECAY_BPS_PER_DAY = 100; // idle mass bleeds ~1%/day (burned)
    uint256 internal constant DAY = 86_400;
    // QUICKDRAW-1: the retail safety floor. balance at/below this is an inert HUSK (never a hand, never prey).
    uint128 public constant SAFE_FLOOR = 5e18;
    // QUICKDRAW-1 percentage floor: a hand keeps max(SAFE_FLOOR, FLOOR_BPS% of its earned PEAK) un-eatable, so
    // an eat can never grind it below that. 6000 = a holder can lose at most 40% of its peak to predation.
    // This is the gentle<->stakes dial. 7500 = a holder can lose at most 25% of its peak (of which the eat
    // takes 90%), everyone survives with a wide safety margin; lower (6000) for more stakes, 8000 nearly cosmetic.
    uint16  internal constant FLOOR_BPS = 7500;
    // â”€â”€ ETH bloodstream split (the eat-bounty) â”€â”€
    uint16  internal constant BOUNTY_DRAW_BPS  = 2000; // a kill drinks 20% of the STANDING bounty pool (self-limiting)
    uint16  internal constant ETH_INHERIT_BPS  = 7000; // 70% of the prey's banked ETH -> predator
    uint16  internal constant ETH_SPORE_BPS    = 1000; // 10% of the prey's banked ETH -> prey owner (pull); rest recycles
    // WALL-CLOCK: timestamp-based, so it never depends on block pacing (about 180 Base blocks).
    uint64  internal constant KILL_COOLDOWN    = 6 minutes; // a predator waits this long before drawing the bounty again
    // POST-EAT SHIELD: a hand that is eaten becomes un-eatable for this long. Keyed to its address (handId) and
    // written ONLY in `_eat` — never in `_resync` — so it SURVIVES buys and sells (a trade can never clear it).
    uint64  internal constant EAT_SHIELD       = 1 hours;
    // ORDERING INVARIANT — CHECK THIS BEFORE RETUNING EITHER NUMBER.
    // FEED_FATIGUE must stay >= EAT_SHIELD. Fatigue writes shieldUntil with a plain assignment, so if it were
    // ever the SHORTER of the two it would CUT A LIVE POST-EAT SHIELD SHORT — silently, with no test failing
    // unless one is written for exactly that case. A predator can carry a live post-eat shield while hunting
    // (the shield only blocks being eaten, not hunting), so the collision is reachable in normal play.
    // Current margin is thin: FEED_FATIGUE 80 min vs EAT_SHIELD 60 min = 20 minutes of headroom.
    // Drop fatigue below the shield, or raise the shield above fatigue, and that write needs a max().
    // ── PREDATOR FATIGUE ── the counterweight to the apex problem. Simulation showed that with identical
    // wallets and identical trade flow, ONE hand still took 42% of all draws and was never eaten once: the
    // predator is picked as the heavier of two samples, so the biggest hand in a bucket keeps winning, and
    // the top occupied bucket has no bucket above it to be preyed on from. After FEED_STREAK_MAX kills in a
    // row a hand must sit out FEED_FATIGUE, and the meal passes to the other sampled predator instead of
    // being wasted — so the draws redistribute rather than merely slowing down. Resting is symmetric: a
    // fatigued hand can neither hunt NOR be hunted, so it reads as a nap rather than a punishment.
    //
    // TUNED ON MEASURED DATA (identical-wallet 24h control; leader's share of all draws / total draws):
    //   no fatigue      42% / 26      one hand dominated and was never eaten
    //   5 in a row, 7h  30% / 27
    //   3 in a row, 7h  27% / 22      over-throttled: -19% draws, 8 wallets ended with zero kills
    //   3 in a row, 4h  29% / 24      chosen at first
    //   3 in a row, 80m           <-- current: shortened again once the post-eat shield came down to 1h
    uint32  internal constant FEED_STREAK_MAX  = 3;       // kills in a row before a hand must rest
    uint64  internal constant FEED_FATIGUE     = 80 minutes; // how long it sits out (cannot eat OR be eaten)

    struct Hand {
        address owner;      // == address(uint160(handId)); kept for cheap reads + NFT mirror
        uint128 mass;       // DERIVED: max(0, balanceOf(owner) - SAFE_FLOOR)
        uint64  bornAt;     // (re)set on each activation; the birth of the current hand, for views
        uint32  kills;
        uint16  bucket;     // current bucket (0..127)
        uint32  bucketPos;  // index within bucketHands[bucket] (for O(1) swap-and-pop)
        uint64  lastTouch;  // for metabolic decay
        bool    alive;
        // ── PREDATOR FATIGUE ── consecutive kills, and the clock that sits a glutton out. Both land in the
        // SAME storage slot as bucketPos/lastTouch/alive (13 bytes used of 32), so tracking this is free:
        // no extra SSTORE, no extra slot. See _eat.
        uint32  feedStreak;   // kills in a row as predator; reset by fatigue, or by being eaten yourself
        uint64  fatigueUntil; // cannot act as predator while block.timestamp < this (shieldUntil mirrors it)
    }

    // handId IS uint256(uint160(owner)). One hand per address.
    mapping(uint256 => Hand) public hands;
    // set ONCE on a hand's first-ever activation, NEVER reset: gates the eat-shield + FEE_WARMUP, so
    // husk-then-rebuy cannot restart either (kills the sybil-immortal-predator + flash-stake vectors).
    mapping(uint256 => uint64) public firstBornAt;
    // POST-EAT immunity clock, keyed by handId (== uint160(owner)). A hand is un-eatable while
    // block.timestamp < shieldUntil[id]. Set ONLY when the hand is eaten (in `_eat`); NEVER touched by
    // `_resync`, so buying or selling does not clear or shorten it. Un-resettable by husk+rebuy (address-keyed),
    // exactly like firstBornAt, so it can't be gamed. See [[EAT_SHIELD]].
    mapping(uint256 => uint64) public shieldUntil;
    // high-water of a hand's EARNED balance; the percentage floor is FLOOR_BPS% of this. Raised on growth,
    // reset on a >50% balance drop (a genuine SELL, never an eat, which is capped at the floor) and on husk.
    // No pump-and-lock: raising a victim's peak only over-protects them, and the gifted tokens can't be
    // clawed back; a flash-loan spike just locks the attacker's own hand OFF the board (mass -> 0).
    mapping(uint256 => uint128) public peak;
    mapping(uint16 => uint256[]) internal bucketHands; // bucket => handIds
    uint256 internal bitmap;                            // bit b set iff bucket b non-empty
    mapping(address => bool) public isExcluded;         // PoolManager/hook/DEAD/initializer/children: never a hand

    // â”€â”€ live-mass bookkeeping (Î£ of all live hand masses; the fee/eth accumulators divide by it) â”€â”€
    uint256 public liveMass;     // maintained ONLY in _resync (+activate / -deactivate / Â±re-mass)
    uint256 public totalSpored;  // cumulative mass left as spore in eaten wallets (stat)
    uint256 public totalBurned;  // cumulative mass burned (eats + decay) (stat)
    // â”€â”€ O(1) UI counters (so the website reads the whole header from the CA, no event-log scans) â”€â”€
    uint256 public liveHands;    // count of hands currently on the board (alive); maintained in _resync
    uint256 public totalEats;    // cumulative successful eats (global); bumped once per eat in _eat

    // â”€â”€ BLOODSTREAM ETH survival stream (the v4-exclusive moat) â”€â”€
    // A wei-exact twin of the fee engine. SINGLE SOURCE OF TRUTH is (ethIn, ethOut) , 
    // accEthPerMass is a pure function of (ethIn, liveMass), never a second drifting balance.
    uint256 public accEthPerMass;                  // ACC_PREC-scaled wei per unit mass
    mapping(uint256 => uint256) public ethDebt;    // handId => accounted-for ETH (UN-divided = mass*acc)
    mapping(uint256 => uint256) public handEth;    // handId => settled, unclaimed wei
    uint256 public handEthTotal;                   // Î£ handEth, maintained incrementally (NO loop)
    // When handEth[id] last GREW: a kill credit (prize + inherited share) or a settle that banked stream ETH.
    // capAdmin may reclaim banked ETH UNCLAIMED_WINDOW after max(this, firstBornAt + FEE_WARMUP), the moment its owner was
    // first allowed to claim it (QuickdrawHook.reclaimableAt / reclaimUnclaimed);
    // every new credit restarts that window.
    mapping(uint256 => uint64) public lastEthCreditAt;
    uint256 public bountyPool;                     // standing ETH bounty: the 1.5% fee + recycled prey ETH; drained 20%/kill; sweepable by capAdmin
    mapping(address => uint256) public bloodClaimable; // ETH owed to owners (eat spore + warm-exit banked); pull-only
    uint256 public bloodClaimableTotal;            // Î£ bloodClaimable
    mapping(uint256 => uint64) internal lastKillAt; // predator's last bounty-draw TIMESTAMP (anti-monopoly cooldown)
    uint256 public ethIn;                          // cumulative ETH skimmed into the stream
    uint256 public ethOut;                         // cumulative ETH paid out of the stream

    event Spawned(uint256 indexed id, address indexed owner, uint128 mass);
    event Husked(uint256 indexed id, address indexed owner, uint128 mass, uint256 fees, uint256 eth);
    event Eaten(
        uint256 indexed predator, uint256 indexed prey,
        uint128 preyMass, uint128 burned, uint128 spore, uint128 predatorMass
    );
    event Claimed(uint256 indexed id, address indexed owner, uint256 fees);
    event Decayed(uint256 indexed id, uint128 lost, uint128 newMass);
    event BloodIn(uint256 amount, bool streamed); // streamed is always false now: every intake is parked in bountyPool
    event EthClaimed(uint256 indexed id, address indexed owner, uint256 amount);
    event BloodEaten(uint256 indexed predator, uint256 indexed prey, uint256 inherited, uint256 spore, uint256 prize);
    event Shielded(uint256 indexed id, address indexed owner, uint64 until); // post-eat immunity granted (survives trades)

    error NotOwner();
    error Dead();
    error NotWarm();

    // â”€â”€ supplied by QuickdrawHook (which reads and moves the DRAW token) â”€â”€
    function _holderBalance(address who) internal view virtual returns (uint256);
    /// RAW balance move (NO _resync): the eat manages hand state itself, so its internal token moves
    /// must NOT re-enter the resync path mid-eat (would corrupt buckets). from/to assumed non-excluded.
    function _moveMass(address from, address to, uint256 amount) internal virtual;
    /// RAW burn from a holder (NO _resync, NO DEAD-address balance): decrements balance + totalSupply.
    function _burnMass(address from, uint256 amount) internal virtual;

    // NFT-mirror lifecycle hooks (default no-op; QuickdrawHook emits ERC-721 events through them)
    function _onHandMint(uint256 id, address owner) internal virtual {}
    function _onHandBurn(uint256 id, address owner) internal virtual {}
    /// Signal an ERC-4906 metadata refresh: a hand's mass changed WITHOUT a mint/burn (e.g. an eat).
    function _onHandSync(uint256 id) internal virtual {}

    function _idOf(address a) internal pure returns (uint256) { return uint256(uint160(a)); }

    /// the un-eatable floor for a hand: the larger of the hard SAFE_FLOOR and FLOOR_BPS% of its peak.
    function _eatFloor(uint256 id) internal view returns (uint128 f) {
        f = uint128(uint256(peak[id]) * FLOOR_BPS / BPS);
        if (f < SAFE_FLOOR) f = SAFE_FLOOR;
    }

    /*//////////////////////// bit / bucket helpers ////////////////////////*/

    // sentinel for a hand that is ALIVE but off the eat board (eatable mass == 0): it sits in NO bucket,
    // so the bitmap + bucket arrays only ever contain real, eatable hands (mass > 0). liveHands counts
    // exactly the on-board hands (maintained in _insert/_removeFromBucket).
    uint16 internal constant NO_BUCKET = type(uint16).max;

    function _msb(uint256 x) internal pure returns (uint16 r) {
        if (x >= 0x100000000000000000000000000000000) { x >>= 128; r += 128; }
        if (x >= 0x10000000000000000) { x >>= 64; r += 64; }
        if (x >= 0x100000000) { x >>= 32; r += 32; }
        if (x >= 0x10000) { x >>= 16; r += 16; }
        if (x >= 0x100) { x >>= 8; r += 8; }
        if (x >= 0x10) { x >>= 4; r += 4; }
        if (x >= 0x4) { x >>= 2; r += 2; }
        if (x >= 0x2) { r += 1; }
    }

    function _bucketOf(uint128 mass) internal pure returns (uint16 b) {
        b = _msb(uint256(mass));
        if (b > 126) b = 126; // never occupy bucket 127 (it has no predator bucket b+1). Unreachable at
                              // the 100k supply (would need ~1.7e20 DRAW), so this is correctness future-proofing.
    }
    function _setBit(uint16 b) internal { bitmap |= (uint256(1) << b); }
    function _clearBit(uint16 b) internal { bitmap &= ~(uint256(1) << b); }

    function _insert(uint256 id) internal {
        Hand storage c = hands[id];
        uint16 b = _bucketOf(c.mass);
        uint256[] storage arr = bucketHands[b];
        c.bucket = b;
        c.bucketPos = uint32(arr.length);
        arr.push(id);
        _setBit(b);
        unchecked { liveHands += 1; } // on the board (a real, eatable hand)
    }

    function _removeFromBucket(uint256 id) internal {
        Hand storage c = hands[id];
        uint16 b = c.bucket;
        uint256[] storage arr = bucketHands[b];
        uint32 pos = c.bucketPos;
        uint256 lastId = arr[arr.length - 1];
        arr[pos] = lastId;
        hands[lastId].bucketPos = pos;
        arr.pop();
        if (arr.length == 0) _clearBit(b);
        unchecked { liveHands -= 1; } // off the board (eaten/husked/shrunk away)
    }

    /*//////////////////////// BLOODSTREAM ETH engine ////////////////////////*/
    /* A wei-exact twin of the fee engine. Intake is parked in bountyPool (nothing streams on intake);
       accEthPerMass only re-apportions a husk's forfeited kill ETH to survivors. Egress is transfer-free
       here, QuickdrawHook drains the payable wei and does the actual send under CEI. */

    /// Take NEW `amount` of ETH into the bloodstream (counts as ETH-in): ALL of it is parked in bountyPool,
    /// the pool every winner drinks from. Nothing streams to holders for holding any more; the only ETH a
    /// holder earns is won (the bounty prize + the loser's banked ETH) and is claimable via claimEth.
    function _intakeBlood(uint256 amount) internal {
        if (amount == 0) return;
        ethIn += amount;
        bountyPool += amount;
        emit BloodIn(amount, false);
    }

    /// Re-apportion ALREADY-held ETH (forfeited by a HUSK) to survivors. Does NOT bump ethIn. No
    /// survivors -> the wei stays in the stream reserve / bountyPool (kept solvent; never dropped).
    function _reapportionEth(uint256 amount) internal {
        if (amount == 0 || liveMass == 0) return;
        accEthPerMass += amount * ACC_PREC / liveMass;
    }

    function _pendingEth(uint256 id) internal view returns (uint256) {
        return (uint256(hands[id].mass) * accEthPerMass - ethDebt[id]) / ACC_PREC;
    }

    /// Move a hand's accrued ETH into its settled bucket and re-baseline its debt. handEthTotal moves
    /// in the SAME statement handEth changes (incremental Î£, no loop).
    function _settleEth(uint256 id) internal {
        uint256 p = _pendingEth(id);
        if (p > 0) { handEth[id] += p; handEthTotal += p; lastEthCreditAt[id] = uint64(block.timestamp); }
        ethDebt[id] = uint256(hands[id].mass) * accEthPerMass;
    }

    /// Settle + DRAIN a hand's payable ETH for an egress (claimEth). Transfer-free: returns the wei,
    /// zeroes handEth, decrements handEthTotal, bumps ethOut. QuickdrawHook performs the actual send (CEI).
    function _drainEth(uint256 id) internal returns (uint256 amount) {
        _settleEth(id);
        amount = handEth[id];
        if (amount > 0) {
            handEth[id] = 0;
            handEthTotal -= amount;
            ethOut += amount;
        }
    }

    /// Change a live hand's mass: settle fees+ETH at the old mass, re-bucket if needed, set the new
    /// mass, re-baseline both debts. Does NOT touch liveMass, `_resync` owns that.
    function _changeMass(uint256 id, uint128 newMass) internal {
        _settleEth(id);
        Hand storage c = hands[id];
        bool inB = (c.bucket != NO_BUCKET);
        if (newMass == 0) {
            // alive but eaten/shrunk to the floor: leave the board entirely (no mass-0 husk in bucket 0)
            if (inB) { _removeFromBucket(id); c.bucket = NO_BUCKET; }
            c.mass = 0;
        } else {
            uint16 nb = _bucketOf(newMass);
            if (!inB) { c.mass = newMass; _insert(id); }                 // back on the board from mass 0
            else if (nb != c.bucket) { _removeFromBucket(id); c.mass = newMass; _insert(id); }
            else { c.mass = newMass; }
        }
        ethDebt[id] = uint256(newMass) * accEthPerMass;
    }

    /*//////////////////// the heart: balance-as-mass resync ////////////////////*/

    /// Reconcile an address's hand with its current balance. Called after EVERY balance change.
    /// O(1), and never reverts for a hand reason (a transfer must never brick). BALANCE-PURE: it
    /// only mutates game accounting (accumulators, debts, buckets, liveMass) and emits NFT-mirror
    /// events, it NEVER moves a token, so it is safe to call inside the v4 unlock and re-entrant-safe.
    function _resync(address addr) internal {
        if (addr == address(0) || isExcluded[addr]) return;
        uint256 id = _idOf(addr);
        Hand storage c = hands[id];
        uint256 bal = _holderBalance(addr);
        // floor high-water: raise on growth; reset on a >50% drop (a real SELL, never an eat, which is
        // capped at the floor by construction). The percentage floor then bounds how far this hand is eaten.
        uint128 pk = peak[id];
        if (uint256(uint128(bal)) > pk) { pk = uint128(bal); peak[id] = pk; }
        else if (pk > 0 && bal < uint256(pk) / 2) { pk = uint128(bal); peak[id] = pk; }
        uint128 flr = uint128(uint256(pk) * FLOOR_BPS / BPS);
        if (flr < SAFE_FLOOR) flr = SAFE_FLOOR;
        uint128 eatable = bal > flr ? uint128(bal - flr) : 0; // eatable mass = balance above the percentage floor

        bool wasAlive = c.alive;
        // alive while holding above the HARD floor. A hand eaten down to its percentage floor stays alive at
        // mass 0 (off the eat board, earning no stream, NOT forfeiting) and re-enters when its floor moves.
        bool shouldLive = bal > SAFE_FLOOR;

        if (!wasAlive && !shouldLive) return;
        if (wasAlive && shouldLive && c.mass == eatable) return; // no-op

        if (!wasAlive && shouldLive) {
            // ACTIVATE: a hand is born above the floor. bornAt resets -> warmup restarts (anti-flash).
            c.owner = addr;
            c.mass = eatable;
            c.bornAt = uint64(block.timestamp);
            if (firstBornAt[id] == 0) firstBornAt[id] = uint64(block.timestamp); // once-ever; survives husk+rebuy
            c.lastTouch = uint64(block.timestamp);
            c.alive = true;
            ethDebt[id] = uint256(eatable) * accEthPerMass;
            _insert(id); // _insert maintains liveHands (+1)
            liveMass += eatable;
            // (The bounty is never streamed to holders, not even to the first hand on an empty street: it is only
            // won on a draw or swept by capAdmin.)
            emit Spawned(id, addr, eatable);
            _onHandMint(id, addr);
            return;
        }

        if (wasAlive && !shouldLive) {
            _husk(id, addr);
            return;
        }

        // GROW / SHRINK: mass tracks the new balance.
        uint128 oldMass = c.mass;
        _changeMass(id, eatable);
        if (eatable >= oldMass) liveMass += (eatable - oldMass);
        else liveMass -= (oldMass - eatable);
    }

    /// DEACTIVATE -> HUSK: settle, then forfeit unclaimed stream ETH to survivors. Warm or cold, exit forfeits
    /// (claim before you sell). Solvent: ETH re-streamed (or parked) without an ethIn bump. Reached from _resync when
    /// a balance falls to the hard floor, and from QuickdrawHook.excludeFromGame (the same rules, applied at once).
    function _husk(uint256 id, address addr) internal {
        Hand storage c = hands[id];
        _settleEth(id);
        uint256 e = handEth[id];
        if (e > 0) { handEth[id] = 0; handEthTotal -= e; }
        uint128 lost = c.mass;
        if (c.bucket != NO_BUCKET) _removeFromBucket(id); // skip if already off-board at mass 0 (maintains liveHands)
        c.bucket = NO_BUCKET;
        liveMass -= lost; // lost == 0 if it was already off-board
        c.mass = 0;
        c.alive = false;
        peak[id] = 0;    // reset the floor high-water so a re-buy starts fresh (no stale giant floor)
        ethDebt[id] = 0; // a husk earns nothing; zero the baseline so views never underflow on it
        // re-owe to survivors (mass already off the board, so it lands on others only)
        if (e > 0) { if (liveMass > 0) _reapportionEth(e); else bountyPool += e; }
        emit Husked(id, addr, lost, 0, e);
        _onHandBurn(id, addr);
    }

    /// Resync both endpoints of a transfer (called by QuickdrawHook after a balance move). O(1).
    function _afterBalance(address from, address to) internal {
        _resync(from);
        if (to != from) _resync(to);
    }
    function _afterBalance(address who) internal { _resync(who); }

    /*//////////////////////////// metabolic decay ////////////////////////////*/

    /// Lazily bleed a hand's mass since last touch by BURNING real balance (capped at half per touch
    /// so decay alone can never annihilate a hand). Reconciles via _resync (may drop it to a HUSK).
    function _touch(uint256 id) internal {
        Hand storage c = hands[id];
        if (!c.alive) return;
        uint64 nowTs = uint64(block.timestamp);
        uint64 last = c.lastTouch;
        c.lastTouch = nowTs;
        if (last == 0 || nowTs <= last) return;
        uint256 elapsed = nowTs - last;
        uint256 decay = uint256(c.mass) * DECAY_BPS_PER_DAY * elapsed / (BPS * DAY);
        if (decay == 0) return;
        uint256 cap = uint256(c.mass) / 2;
        if (decay > cap) decay = cap;
        if (decay == 0) return;
        address addr = c.owner;
        _burnMass(addr, decay);     // raw burn from the holder's real balance (no resync here)
        totalBurned += decay;
        _resync(addr);              // reconcile mass from the new balance (settles + re-buckets / husks)
        emit Decayed(id, uint128(decay), hands[id].mass);
    }

    /*//////////////////////////// claims ////////////////////////////*/

    /// Claim accrued fees for a warmed-up hand. Owner-only. Settles the ETH stream too so a $DRAW-fee
    /// claim never strands pending ETH (the ETH itself is drained via QuickdrawHook.claimEth).
    function _claim(uint256 id, address caller) internal returns (uint256 fees) {
        Hand storage c = hands[id];
        if (!c.alive) revert Dead();
        if (c.owner != caller) revert NotOwner();
        if (block.timestamp < uint256(firstBornAt[id]) + FEE_WARMUP) revert NotWarm();
        _touch(id);
        if (!c.alive) return 0; // decay husked it; nothing to claim (fees were forfeited)
        _settleEth(id); // bank pending ETH into handEth so it survives later mass changes
        emit Claimed(id, c.owner, fees);
    }

    /// Settle + drain a warmed-up hand's payable stream ETH. Owner-only, transfer-free.
    function _claimEth(uint256 id, address caller) internal returns (uint256 amount) {
        Hand storage c = hands[id];
        if (!c.alive) revert Dead();
        if (c.owner != caller) revert NotOwner();
        if (block.timestamp < uint256(firstBornAt[id]) + FEE_WARMUP) revert NotWarm();
        _touch(id);
        if (!c.alive) return 0;
        amount = _drainEth(id);
        emit EthClaimed(id, c.owner, amount);
    }

    /*////////////////////////////// the eat //////////////////////////////*/

    /// Pick the (seed mod popcount)-th set bit of `mask`. Bounded loop over the 128 buckets.
    function _pickBucket(uint256 mask, uint256 seed) internal pure returns (uint16) {
        uint256 cnt;
        for (uint256 m = mask; m != 0; m &= (m - 1)) cnt++;
        uint256 target = seed % cnt;
        uint256 i;
        for (uint16 bb = 0; bb < 128; bb++) {
            if (((mask >> bb) & 1) == 1) { if (i == target) return bb; i++; }
        }
        return 0;
    }

    /// One eat, driven by a volume-derived seed. RUNG LADDER: prey from bucket b, predator from the
    /// bucket directly above (b+1), so the predator/prey mass ratio is bounded to (1, 4), a whale can
    /// never reach a minnow. Moves REAL balance: prey -> predator (70%) + burn (20%), prey keeps a 10%
    /// spore. The prey is KNOCKED DOWN, not wiped. Strictly O(1); a failed gate is a no-op (never a
    /// revert that would brick the swap). Token moves are RAW; hand state is reconciled by _resync after.
    function _eat(uint256 seed) internal {
        uint256 adj = bitmap & (bitmap >> 1);
        if (adj == 0) return; // no near-peer pair on the board -> no eat (honors the <=4x promise)
        uint16 b = _pickBucket(adj, seed);
        uint256[] storage low = bucketHands[b];
        uint256[] storage high = bucketHands[b + 1];
        if (low.length == 0 || high.length == 0) return; // defensive

        // prey bucket: EAT-THE-LIGHTER of two samples (sybil dust becomes preferred prey);
        // predator bucket: take the HEAVIER. Both O(1).
        uint256 pa = low[seed % low.length];
        uint256 pb = low[(seed >> 8) % low.length];
        uint256 preyId = hands[pa].mass <= hands[pb].mass ? pa : pb;
        uint256 qa = high[(seed >> 16) % high.length];
        uint256 qb = high[(seed >> 24) % high.length];
        uint256 predId = hands[qa].mass >= hands[qb].mass ? qa : qb;
        // PREDATOR FATIGUE: the heavier sample is still preferred, but a hand resting off a FEED_STREAK_MAX
        // streak hands the meal to the OTHER sample rather than aborting. That distinction is the whole point:
        // aborting would waste the draw and just slow the game down, whereas passing it along actually moves
        // kills off the leader and onto the rest of the bucket.
        if (block.timestamp < uint256(hands[predId].fatigueUntil)) predId = (predId == qa ? qb : qa);
        if (block.timestamp < uint256(hands[predId].fatigueUntil)) return; // both sampled predators resting
        if (predId == preyId) return; // defensive (different buckets, so never equal)

        if (hands[preyId].mass < DUST_FLOOR) return;
        if (block.timestamp < uint256(firstBornAt[preyId]) + MIN_AGE) return; // prey shield (FIRST birth, un-resettable)
        if (block.timestamp < uint256(shieldUntil[preyId])) return;           // POST-EAT shield: still recovering,
                                                                              // and it held through any buys/sells since

        // the PREDATOR must also be established (>= PRED_MIN_AGE, five minutes — far longer than the prey's
        // 30s): a flash-created, board-shaped predator can't be spun up to aim the eat at a chosen victim on a
        // sparse board (hardens the un-aimable property).
        if (block.timestamp < uint256(firstBornAt[predId]) + PRED_MIN_AGE) return;

        _touch(predId); // decay the predator before it feeds (idle titans can't dodge the tax)
        if (!hands[predId].alive) return; // decay husked it; abort

        uint128 pm = hands[preyId].mass;
        uint128 prdM = hands[predId].mass;
        if (uint256(prdM) * RATIO_DEN < uint256(pm) * RATIO_NUM) return; // ratio gate (post-decay)

        uint128 spore = uint128(uint256(pm) * SPORE_BPS / BPS);
        uint128 burn  = uint128(uint256(pm) * BURN_BPS / BPS);
        uint128 gain  = pm - spore - burn;
        address preyAddr = hands[preyId].owner;
        address predAddr = hands[predId].owner;

        // settle the prey's banked stream ETH (about to be inherited / spored / recycled)
        _settleEth(preyId);
        uint256 preyEth = handEth[preyId];
        if (preyEth > 0) { handEth[preyId] = 0; handEthTotal -= preyEth; }

        // â”€â”€ ETH bloodstream on a kill (pure bucket-to-bucket; ethIn/ethOut unchanged, so solvent):
        //    predator drinks 20% of the STANDING bounty (cooldown-gated) + 70% of the prey's banked
        //    ETH; the prey owner keeps a 10% ETH spore (pull); the remaining 20% recycles to bounty.
        uint256 prize = 0;
        if (lastKillAt[predId] == 0 || block.timestamp >= uint256(lastKillAt[predId]) + KILL_COOLDOWN) {
            prize = bountyPool * BOUNTY_DRAW_BPS / BPS;
            bountyPool -= prize;
            lastKillAt[predId] = uint64(block.timestamp);
        }
        uint256 ethInherit = preyEth * ETH_INHERIT_BPS / BPS;
        uint256 ethSpore = preyEth * ETH_SPORE_BPS / BPS;
        uint256 ethRecycle = preyEth - ethInherit - ethSpore;
        uint256 toPred = ethInherit + prize;
        if (toPred > 0) { handEth[predId] += toPred; handEthTotal += toPred; lastEthCreditAt[predId] = uint64(block.timestamp); }
        if (ethSpore > 0) { bloodClaimable[preyAddr] += ethSpore; bloodClaimableTotal += ethSpore; }
        if (ethRecycle > 0) bountyPool += ethRecycle;

        // â”€â”€ REAL balance moves (RAW, no resync): prey -> predator (gain) + burn. Spore stays put.
        _moveMass(preyAddr, predAddr, gain);
        if (burn > 0) _burnMass(preyAddr, burn);
        totalSpored += spore;
        totalBurned += burn;

        // â”€â”€ reconcile both hands from their new balances (predator grew, prey knocked down / husked).
        // _resync is balance-pure, so doing it AFTER both raw moves keeps the buckets coherent.
        _resync(predAddr);
        _resync(preyAddr);
        hands[predId].kills += 1; // resync preserves kills; bump after the grow
        // FATIGUE BOOKKEEPING: another kill on the streak; at the cap the hand sits out FEED_FATIGUE. Being
        // eaten yourself breaks your own streak — you were knocked down, you are not mid-hunt any more.
        {
            Hand storage pc = hands[predId];
            unchecked { pc.feedStreak += 1; }
            if (pc.feedStreak >= FEED_STREAK_MAX) {
                pc.feedStreak = 0;
                uint64 until = uint64(block.timestamp) + FEED_FATIGUE;
                pc.fatigueUntil = until;   // cannot HUNT while resting
                // ...and cannot BE HUNTED either: a resting hand is out of the game in both directions, which
                // is what makes fatigue read as a rest rather than a punishment. Reusing shieldUntil means the
                // prey-side gate already enforces this — no extra branch in the hot path. A plain assignment is
                // safe ONLY because FEED_FATIGUE (80 min) exceeds EAT_SHIELD (1h), so this can only ever extend
                // a live shield, never cut one short. That 20-minute margin is the whole safety proof — see the
                // ORDERING INVARIANT at the constants. Shrink FEED_FATIGUE below EAT_SHIELD and this line
                // silently truncates a shield a player already earned.
                shieldUntil[predId] = until;
            }
            hands[preyId].feedStreak = 0;
        }
        unchecked { totalEats += 1; } // global eat count (one read replaces an Eaten log scan)

        // POST-EAT SHIELD: the prey just got knocked down, so give it EAT_SHIELD of immunity. Keyed to the
        // prey's ADDRESS, so it persists no matter how the owner trades afterward: a buy or sell re-runs _resync,
        // and _resync never touches shieldUntil, so a trade can never re-expose the hand.
        uint64 until = uint64(block.timestamp) + EAT_SHIELD;
        shieldUntil[preyId] = until;
        emit Shielded(preyId, preyAddr, until);

        // ERC-4906: the eat changes both hands' rendered mass without a mint/burn, so signal a refresh
        // (a husked prey already emitted an ERC-721 burn via _onHandBurn).
        _onHandSync(predId);
        if (hands[preyId].alive) _onHandSync(preyId);

        emit Eaten(predId, preyId, pm, burn, spore, hands[predId].mass);
        emit BloodEaten(predId, preyId, ethInherit, ethSpore, prize);

    }

    /*////////////////////////////// views //////////////////////////////*/

    // NOTE: no feeSolvent()/ethSolvent() views (`totalFeesOut<=totalFeesIn` / `ethOut<=ethIn`): both are
    // trivially derived off-chain from the public counters.
    /// The ETH the bloodstream owns, which no sweep may ever touch. `ethIn - ethOut` ==
    /// handEthTotal + bountyPool + bloodClaimableTotal + Î£ pendingEth always, so it never under-counts.
    function bloodReserve() public view virtual returns (uint256) { return ethIn - ethOut; }
    // NOTE: no pendingFees() view: there is no token-side fee, so it would always read 0.
    // NOTE: no shieldRemaining()/isShielded() helpers — QuickdrawHook stays well under the EIP-170 size limit and both are
    // trivially derived off-chain from the public `shieldUntil(id)` mapping:
    //   isShielded      = now < shieldUntil[id]
    //   shieldRemaining = shieldUntil[id] > now ? shieldUntil[id] - now : 0
    // NOTE: dropped pendingEth() external view (was handEth[id] + _pendingEth(id)) for EIP-170 headroom —
    // handPage() already returns each hand's total claimable stream ETH, which is all the UI needs.
    // NOTE: dropped bucketLen()/bucketAt()/dishBitmap() to stay under the EIP-170 limit — handPage() already
    // pages the whole board for the UI, so these low-level bucket accessors weren't needed.

    /// Page the LIVE board in ONE call so the website never needs a Spawned-log scan or a per-hand
    /// multicall. Walks the mass-ordered buckets from `fromBucket` DOWNWARD (bucket = msb(mass), so a
    /// higher bucket is heavier), starting at index `cursor` within that bucket, returning up to `max`
    /// hands with everything the street + leaderboards + inspector need (id, owner, mass, kills, claimable
    /// stream ETH). (nextBucket, nextCursor, done) is an opaque resume token: call again with them until
    /// `done`. Top->bottom order IS the mass leaderboard (row 0 is the titan). Pure view; reads only.
    /// To page the whole board: start at (126, 0, max) and loop on the returned token while !done.
    function handPage(uint16 fromBucket, uint256 cursor, uint256 max)
        external
        view
        returns (
            uint256[] memory ids,
            address[] memory owners,
            uint128[] memory masses,
            uint32[] memory killsArr,
            uint256[] memory pendingEthWei,
            uint16 nextBucket,
            uint256 nextCursor,
            bool done
        )
    {
        if (fromBucket > 126) fromBucket = 126;
        // guard: a 0-page is immediately "done" (so a client never loops forever on max==0)
        if (max == 0) {
            return (new uint256[](0), new address[](0), new uint128[](0), new uint32[](0), new uint256[](0), fromBucket, cursor, true);
        }
        ids = new uint256[](max);
        owners = new address[](max);
        masses = new uint128[](max);
        killsArr = new uint32[](max);
        pendingEthWei = new uint256[](max);

        uint256 k = 0;
        uint16 b = fromBucket;
        uint256 i = cursor;
        done = true;
        while (true) {
            uint256[] storage arr = bucketHands[b];
            uint256 len = arr.length;
            while (i < len) {
                if (k == max) { nextBucket = b; nextCursor = i; done = false; break; }
                uint256 id = arr[i];
                Hand storage c = hands[id];
                ids[k] = id;
                owners[k] = c.owner;
                masses[k] = c.mass;
                killsArr[k] = c.kills;
                pendingEthWei[k] = handEth[id] + _pendingEth(id);
                unchecked { k++; i++; }
            }
            if (!done) break;     // hit the page limit
            if (b == 0) break;    // walked the whole board
            unchecked { b--; }
            i = 0;
        }
        // shrink the over-allocated arrays to the actual count k (memory was sized for `max`). Only the
        // length words are rewritten, strictly within already-allocated memory -> memory-safe.
        assembly ("memory-safe") {
            mstore(ids, k)
            mstore(owners, k)
            mstore(masses, k)
            mstore(killsArr, k)
            mstore(pendingEthWei, k)
        }
    }
}
