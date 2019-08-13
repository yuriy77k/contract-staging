pragma solidity 0.5.10;

import "./GlobalsAndUtility.sol";

contract StakeableToken is GlobalsAndUtility {
    /**
     * @dev PUBLIC FACING: Open a stake.
     * @param newStakedHearts Number of Hearts to stake
     * @param newStakedDays Number of days to stake
     */
    function startStake(uint256 newStakedHearts, uint256 newStakedDays)
        external
    {
        GlobalsCache memory g;
        GlobalsCache memory gSnapshot;
        _loadGlobals(g, gSnapshot);

        /* Enforce the minimum stake time */
        require(newStakedDays >= MIN_STAKE_DAYS, "HEX: newStakedDays lower than minimum");

        /* Check if log data needs to be updated */
        _storeDailyDataBefore(g, g._currentDay);

        _startStake(g, newStakedHearts, newStakedDays, false);

        /* Remove staked Hearts from balance of staker */
        _burn(msg.sender, newStakedHearts);

        _syncGlobals(g, gSnapshot);
    }

    /**
     * @dev PUBLIC FACING: Removes a completed stake from the global pool,
     * distributing the proceeds of any penalty immediately. The staker must
     * still call endStake() to retrieve their stake return (if any).
     * @param stakerAddr Address of staker
     * @param stakeIndex Index of stake within stake list
     * @param stakeIdParam The stake's id
     */
    function goodAccounting(address stakerAddr, uint256 stakeIndex, uint40 stakeIdParam)
        external
    {
        GlobalsCache memory g;
        GlobalsCache memory gSnapshot;
        _loadGlobals(g, gSnapshot);

        /* require() is more informative than the default assert() */
        require(staked[stakerAddr].length != 0, "HEX: Empty stake list");
        require(stakeIndex < staked[stakerAddr].length, "HEX: stakeIndex invalid");

        StakeStore storage stRef = staked[stakerAddr][stakeIndex];

        /* Get stake copy */
        StakeCache memory st;
        _loadStake(stRef, stakeIdParam, st);

        /* Stake must have served full term */
        require(g._currentDay >= st._pooledDay + st._stakedDays, "HEX: Stake not fully served");

        /* Stake must be in still in global pool */
        require(st._unpooledDay == 0, "HEX: Stake already unpooled");

        /* Check if log data needs to be updated */
        _storeDailyDataBefore(g, g._currentDay);

        /* Remove stake from global pool */
        _unpoolStake(g, st);

        /* stakeReturn value is unused here */
        (, uint256 payout, uint256 penalty, uint256 cappedPenalty) = _calcStakeReturn(
            g,
            st,
            st._stakedDays
        );

        emit GoodAccounting(
            uint40(block.timestamp),
            stakerAddr,
            stakeIdParam,
            payout,
            penalty,
            msg.sender
        );

        if (cappedPenalty != 0) {
            _splitPenaltyProceeds(g, cappedPenalty);
        }

        /* st._unpooledDay has changed */
        _updateStake(stRef, st);

        _syncGlobals(g, gSnapshot);
    }

    /**
     * @dev PUBLIC FACING: Closes a stake. The order of the stake list can change so
     * a stake id is used to reject stale indexes.
     * @param stakeIndex Index of stake within stake list
     * @param stakeIdParam The stake's id
     */
    function endStake(uint256 stakeIndex, uint40 stakeIdParam)
        external
    {
        GlobalsCache memory g;
        GlobalsCache memory gSnapshot;
        _loadGlobals(g, gSnapshot);

        StakeStore[] storage stakeListRef = staked[msg.sender];

        /* require() is more informative than the default assert() */
        require(stakeListRef.length != 0, "HEX: Empty stake list");
        require(stakeIndex < stakeListRef.length, "HEX: stakeIndex invalid");

        /* Get stake copy */
        StakeCache memory st;
        _loadStake(stakeListRef[stakeIndex], stakeIdParam, st);

        /* Check if log data needs to be updated */
        _storeDailyDataBefore(g, g._currentDay);

        uint256 servedDays = 0;

        bool prevUnpooled = (st._unpooledDay != 0);
        uint256 stakeReturn;
        uint256 payout = 0;
        uint256 penalty = 0;
        uint256 cappedPenalty = 0;

        if (g._currentDay >= st._pooledDay) {
            if (prevUnpooled) {
                /* Previously unpooled in goodAccounting(), so must have served full term */
                servedDays = st._stakedDays;
            } else {
                _unpoolStake(g, st);

                servedDays = g._currentDay - st._pooledDay;
                if (servedDays > st._stakedDays) {
                    servedDays = st._stakedDays;
                } else {
                    /* Deny early-unstake before an auto-stake minimum has been served */
                    if (servedDays < MIN_AUTO_STAKE_DAYS) {
                        require(!st._isAutoStake, "HEX: Auto-stake still locked");
                    }
                }
            }

            (stakeReturn, payout, penalty, cappedPenalty) = _calcStakeReturn(g, st, servedDays);
        } else {
            /* Deny early-unstake before an auto-stake minimum has been served */
            require(!st._isAutoStake, "HEX: Auto-stake still locked");

            /* Stake hasn't been added to the global pool yet, so no penalties or rewards apply */
            g._nextStakeSharesTotal -= st._stakeShares;

            stakeReturn = st._stakedHearts;
        }

        emit EndStake(
            uint40(block.timestamp),
            msg.sender,
            stakeIdParam,
            payout,
            penalty,
            uint16(servedDays)
        );

        if (cappedPenalty != 0 && !prevUnpooled) {
            /* Split penalty proceeds only if not previously unpooled by goodAccounting() */
            _splitPenaltyProceeds(g, cappedPenalty);
        }

        /* Pay the stake return, if any, to the staker */
        if (stakeReturn != 0) {
            _mint(msg.sender, stakeReturn);

            /* Update the share rate if necessary */
            _updateShareRate(g, st, stakeReturn);
        }
        g._lockedHeartsTotal -= st._stakedHearts;

        _removeStakeFromList(stakeListRef, stakeIndex);

        _syncGlobals(g, gSnapshot);
    }

    /**
     * @dev PUBLIC FACING: Return the current stake count for a staker address
     * @param stakerAddr Address of staker
     */
    function getStakeCount(address stakerAddr)
        external
        view
        returns (uint256)
    {
        return staked[stakerAddr].length;
    }

    /**
     * @dev Open a stake.
     * @param g Cache of stored globals
     * @param newStakedHearts Number of Hearts to stake
     * @param newStakedDays Number of days to stake
     * @param newAutoStake Stake is automatic directly from a new claim
     */
    function _startStake(
        GlobalsCache memory g,
        uint256 newStakedHearts,
        uint256 newStakedDays,
        bool newAutoStake
    )
        internal
    {
        /* Enforce the maximum stake time */
        require(newStakedDays <= MAX_STAKE_DAYS, "HEX: newStakedDays higher than maximum");

        uint256 bonusHearts = _calcStakeBonusHearts(newStakedHearts, newStakedDays);
        uint256 newStakeShares = (newStakedHearts + bonusHearts) * SHARE_RATE_SCALE / g._shareRate;

        /* Ensure newStakedHearts is enough for at least one stake share */
        require(newStakeShares != 0, "HEX: newStakedHearts must be at least minimum shareRate");

        /*
            The startStake timestamp will always be part-way through the current
            day, so it needs to be rounded-up to the next day to ensure all
            stakes align with the same fixed calendar days. The current day is
            already rounded-down, so rounded-up is current day + 1.
        */
        uint256 newPooledDay = g._currentDay < CLAIM_PHASE_START_DAY
            ? CLAIM_PHASE_START_DAY + 1
            : g._currentDay + 1;

        /* Create Stake */
        uint40 newStakeId = ++g._latestStakeId;
        _addStake(
            staked[msg.sender],
            newStakeId,
            newStakedHearts,
            newStakeShares,
            newPooledDay,
            newStakedDays,
            newAutoStake
        );

        emit StartStake(
            uint40(block.timestamp),
            msg.sender,
            newStakeId,
            newStakedHearts,
            newStakeShares,
            uint16(newStakedDays),
            newAutoStake
        );

        /* Stake is added to pool in next round, not current round */
        g._nextStakeSharesTotal += newStakeShares;

        /* Track total staked Hearts for inflation calculations */
        g._lockedHeartsTotal += newStakedHearts;
    }

    /**
     * @dev Calculates total stake payout including rewards for a multi-day range
     * @param g Cache of stored globals
     * @param stakeSharesParam Param from stake to calculate bonuses for
     * @param beginDay First day to calculate bonuses for
     * @param endDay Last day (non-inclusive) of range to calculate bonuses for
     * @return Payout in Hearts
     */
    function _calcPayoutRewards(
        GlobalsCache memory g,
        uint256 stakeSharesParam,
        uint256 beginDay,
        uint256 endDay
    )
        private
        view
        returns (uint256 payout)
    {
        for (uint256 day = beginDay; day < endDay; day++) {
            payout += dailyData[day].dayPayoutTotal * stakeSharesParam / dailyData[day].dayStakeSharesTotal;
        }

        /* Less expensive to re-read storage than to have the condition inside the loop */
        if (beginDay <= WAAS_LUMP_DAY && endDay > WAAS_LUMP_DAY) {
            uint256 waasRound = g._unclaimedSatoshisTotal * HEARTS_PER_SATOSHI * stakeSharesParam / dailyData[WAAS_LUMP_DAY].dayStakeSharesTotal;

            payout += waasRound + _calcAdoptionBonus(g, waasRound);
        }
        return payout;
    }

    /**
     * @dev Calculate bonus Hearts for a new stake, if any
     * @param newStakedHearts Number of Hearts to stake
     * @param newStakedDays Number of days to stake
     */
    function _calcStakeBonusHearts(uint256 newStakedHearts, uint256 newStakedDays)
        private
        pure
        returns (uint256 bonusHearts)
    {
        /*
            LONGER PAYS BETTER:

            If longer than 1 day stake is committed to, each extra day
            gives bonus shares of approximately 0.0548%, which is approximately 20%
            extra per year of increased stakelength committed to, but capped to a
            maximum of 200% extra.

            extraDays       =  stakedDays - 1

            longerBonus%    = (extraDays / 364) * 20%
                            = (extraDays / 364) / 5
                            =  extraDays / 1820
                            =  extraDays / LPB

            extraDays       =  longerBonus% * 1820
            extraDaysCap    =  longerBonusCap% * 1820
                            =  200% * 1820
                            =  3640
                            =  LPB_CAP_DAYS

            longerAmount    =  hearts * longerBonus%

            BIGGER PAYS BETTER:

            Bonus percentage scaled 0% to 10% for the first 150M HEX of stake.

            biggerBonus%    = (hearts /  BPB_CAP_HEARTS) * 10%
                            = (hearts /  BPB_CAP_HEARTS) / 10
                            =  hearts / (BPB_CAP_HEARTS * 10)
                            =  hearts /  BPB

            biggerAmount    =  hearts * biggerBonus%

            combinedBonus%  =      longerBonus%  +  biggerBonus%

                                      extraDays     hearts
                            =         ---------  +  ------
                                         LPB         BPB

                                extraDays * BPB     hearts * LPB
                            =   ---------------  +  ------------
                                   LPB * BPB          LPB * BPB

                                extraDays * BPB  +  hearts * LPB
                            =   --------------------------------
                                            LPB * BPB

            bonusHearts     = hearts * combinedBonus%
                            = hearts * (extraDays * BPB  +  hearts * LPB) / (LPB * BPB)
        */
        uint256 cappedExtraDays = 0;

        /* Must be more than 1 day for Longer-Pays-Better */
        if (newStakedDays > 1) {
            cappedExtraDays = newStakedDays <= LPB_CAP_DAYS ? newStakedDays - 1 : LPB_CAP_DAYS;
        }

        uint256 cappedStakedHearts = newStakedHearts <= BPB_CAP_HEARTS
            ? newStakedHearts
            : BPB_CAP_HEARTS;

        bonusHearts = cappedExtraDays * BPB + cappedStakedHearts * LPB;
        bonusHearts = newStakedHearts * bonusHearts / (LPB * BPB);

        return bonusHearts;
    }

    function _unpoolStake(GlobalsCache memory g, StakeCache memory st)
        private
        pure
    {
        g._stakeSharesTotal -= st._stakeShares;
        st._unpooledDay = g._currentDay;
    }

    function _calcStakeReturn(GlobalsCache memory g, StakeCache memory st, uint256 servedDays)
        private
        view
        returns (uint256 stakeReturn, uint256 payout, uint256 penalty, uint256 cappedPenalty)
    {
        if (servedDays < st._stakedDays) {
            (payout, penalty) = _calcPayoutAndEarlyPenalty(
                g,
                st._pooledDay,
                st._stakedDays,
                servedDays,
                st._stakeShares
            );
            stakeReturn = st._stakedHearts + payout;
        } else {
            payout = _calcPayoutRewards(
                g,
                st._stakeShares,
                st._pooledDay,
                st._pooledDay + servedDays
            );
            stakeReturn = st._stakedHearts + payout;

            penalty = _calcLatePenalty(
                st._stakedDays,
                st._unpooledDay - st._pooledDay,
                stakeReturn
            );
        }
        if (penalty != 0) {
            if (penalty > stakeReturn) {
                /* Cannot have a negative stake return */
                cappedPenalty = stakeReturn;
                stakeReturn = 0;
            } else {
                /* Remove penalty from the stake return */
                cappedPenalty = penalty;
                stakeReturn -= cappedPenalty;
            }
        }
        return (stakeReturn, payout, penalty, cappedPenalty);
    }

    /**
     * @dev Calculates served payout and early penalty for early unstake
     * @param g Cache of stored globals
     * @param pooledDayParam Param from stake
     * @param stakedDaysParam Param from stake
     * @param servedDays Number of days actually served
     * @param stakeSharesParam Param from stake
     * @return 1: Payout in Hearts; 2: Penalty in Hearts
     */
    function _calcPayoutAndEarlyPenalty(
        GlobalsCache memory g,
        uint256 pooledDayParam,
        uint256 stakedDaysParam,
        uint256 servedDays,
        uint256 stakeSharesParam
    )
        private
        view
        returns (uint256 payout, uint256 penalty)
    {
        uint256 servedEndDay = pooledDayParam + servedDays;

        /* 50% of stakedDays (rounded up) with a minimum applied */
        uint256 penaltyDays = (stakedDaysParam + 1) / 2;
        if (penaltyDays < EARLY_PENALTY_MIN_DAYS) {
            penaltyDays = EARLY_PENALTY_MIN_DAYS;
        }

        if (servedDays == 0) {
            /* Fill penalty days with the estimated average payout */
            uint256 expected = _estimatePayoutRewardsDay(g, stakeSharesParam, pooledDayParam);
            penalty = expected * penaltyDays;
            return (payout, penalty); // Actual payout was 0
        }

        if (penaltyDays < servedDays) {
            /*
                Simplified explanation of intervals where end-day is non-inclusive:

                penalty:    [pooledDay  ...  penaltyEndDay)
                delta:                      [penaltyEndDay  ...  servedEndDay)
                payout:     [pooledDay  .......................  servedEndDay)
            */
            uint256 penaltyEndDay = pooledDayParam + penaltyDays;
            penalty = _calcPayoutRewards(g, stakeSharesParam, pooledDayParam, penaltyEndDay);

            uint256 delta = _calcPayoutRewards(g, stakeSharesParam, penaltyEndDay, servedEndDay);
            payout = penalty + delta;
            return (payout, penalty);
        }

        /* penaltyDays >= servedDays  */
        payout = _calcPayoutRewards(g, stakeSharesParam, pooledDayParam, servedEndDay);

        if (penaltyDays == servedDays) {
            penalty = payout;
        } else {
            /*
                (penaltyDays > servedDays) means not enough days served, so fill the
                penalty days with the average payout from only the days that were served.
            */
            penalty = payout * penaltyDays / servedDays;
        }
        return (payout, penalty);
    }

    /**
     * @dev Calculates penalty for ending stake late
     * and adds penalty to payout pool
     * @param stakedDaysParam Param from stake
     * @param unpooledDays Stake unpooledDay minus stake pooledDay
     * @param rawStakeReturn Committed stakeHearts plus payout
     * @return Penalty in Hearts
     */
    function _calcLatePenalty(uint256 stakedDaysParam, uint256 unpooledDays, uint256 rawStakeReturn)
        private
        pure
        returns (uint256)
    {
        /* Allow grace time before penalties accrue */
        stakedDaysParam += LATE_PENALTY_GRACE_DAYS;
        if (unpooledDays <= stakedDaysParam) {
            return 0;
        }

        /* Calculate penalty as a percentage of stake return based on time */
        return rawStakeReturn * (unpooledDays - stakedDaysParam) / LATE_PENALTY_SCALE_DAYS;
    }

    function _updateShareRate(GlobalsCache memory g, StakeCache memory st, uint256 stakeReturn)
        private
    {
        if (stakeReturn > st._stakedHearts) {
            uint256 newShareRate = _calcShareRate(st._stakeShares, st._stakedDays, stakeReturn);

            if (newShareRate > g._shareRate) {
                g._shareRate = newShareRate;

                emit ShareRateChange(
                    uint40(block.timestamp),
                    newShareRate,
                    st._stakeId
                );
            }
        }
    }

    function _calcShareRate(uint256 stakeSharesParam, uint256 stakeDaysParam, uint256 stakeReturn)
        private
        pure
        returns (uint256)
    {
        /*
            biggerBonus%    =  hearts /  BPB

            biggerAmount    =  hearts * biggerBonus%
                            =  hearts * hearts / BPB

            newShareRate    = (hearts + biggerAmount) * SHARE_RATE_SCALE / stakeShares
                            = (hearts + hearts * hearts / BPB) * SHARE_RATE_SCALE  /  stakeShares
                            = (hearts * BPB + hearts * hearts) * SHARE_RATE_SCALE  /  stakeShares / BPB
                            = (hearts * BPB + hearts * hearts) * SHARE_RATE_SCALE  / (stakeShares * BPB)
                            = (BPB + hearts) * hearts * SHARE_RATE_SCALE / (stakeShares * BPB)
        */
        uint256 cappedHearts = stakeReturn <= BPB_CAP_HEARTS
            ? stakeReturn
            : BPB_CAP_HEARTS;

        uint256 adjStakeShares = stakeSharesParam;
        if (stakeDaysParam > 1) {
            uint256 cappedExtraDays = stakeDaysParam <= LPB_CAP_DAYS
                ? stakeDaysParam - 1
                : LPB_CAP_DAYS;

            adjStakeShares = stakeSharesParam * LPB / (cappedExtraDays + LPB);
        }

        return (BPB + cappedHearts) * stakeReturn * SHARE_RATE_SCALE / (adjStakeShares * BPB);
    }
}
