pragma solidity 0.5.10;

import "../node_modules/openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";

contract GlobalsAndUtility is ERC20 {
    /* Define events */
    event JoinXfLobby(
        uint40 timestamp,
        address indexed memberAddr,
        uint256 indexed entryId,
        uint256 rawAmount,
        address indexed referrerAddr
    );

    event LeaveXfLobby(
        uint40 timestamp,
        address indexed memberAddr,
        uint256 indexed entryId,
        uint256 xfAmount,
        address indexed referrerAddr
    );

    event DailyDataUpdate(
        uint40 timestamp,
        uint16 daysStoredAdded,
        uint16 daysStoredTotal,
        address indexed updaterAddr
    );

    event Claim(
        uint40 timestamp,
        address indexed claimToAddr,
        bytes20 indexed btcAddr,
        uint256 rawSatoshis,
        uint256 adjSatoshis,
        uint256 claimedHearts,
        address indexed referrerAddr,
        address senderAddr
    );

    event ClaimAssist(
        uint40 timestamp,
        address claimToAddr,
        bytes20 btcAddr,
        uint256 rawSatoshis,
        uint256 adjSatoshis,
        uint256 claimedHearts,
        address referrerAddr,
        address indexed senderAddr
    );

    event StartStake(
        uint40 timestamp,
        address indexed stakerAddr,
        uint40 indexed stakeId,
        uint256 stakedHearts,
        uint256 stakeShares,
        uint16 stakedDays,
        bool isAutoStake
    );

    event GoodAccounting(
        uint40 timestamp,
        address indexed stakerAddr,
        uint40 indexed stakeId,
        uint256 payout,
        uint256 penalty,
        address indexed senderAddr
    );

    event EndStake(
        uint40 timestamp,
        address indexed stakerAddr,
        uint40 indexed stakeId,
        uint256 payout,
        uint256 penalty,
        uint16 servedDays
    );

    event ShareRateChange(
        uint40 timestamp,
        uint256 shareRate,
        uint40 indexed stakeId
    );

    /* Origin address */
    address internal constant ORIGIN_ADDR = 0x20C39E8862cB26Ac16eD0AFB37DCeE7F1BD8F153;

    /* Flush address */
    address payable internal constant FLUSH_ADDR = 0x20C39E8862cB26Ac16eD0AFB37DCeE7F1BD8F153;

    /* ERC20 constants */
    string public constant name = "HEX";
    string public constant symbol = "HEX";
    uint8 public constant decimals = 8;

    /* Hearts per Satoshi = 10,000 * 1e8 / 1e8 = 1e4 */
    uint256 private constant HEARTS_PER_HEX = 10 ** uint256(decimals); // 1e8
    uint256 private constant HEX_PER_BTC = 1e4;
    uint256 private constant SATOSHIS_PER_BTC = 1e8;
    uint256 internal constant HEARTS_PER_SATOSHI = HEARTS_PER_HEX / SATOSHIS_PER_BTC * HEX_PER_BTC;

    /* Time of contract launch (2019-03-04T00:00:00Z) */
    uint256 internal constant LAUNCH_TIME = 1551657600;

    /* Size of a transform lobby entry index uint */
    uint256 internal constant XF_LOBBY_ENTRY_INDEX_SIZE = 40;
    uint256 internal constant XF_LOBBY_ENTRY_INDEX_MASK = (1 << XF_LOBBY_ENTRY_INDEX_SIZE) - 1;

    /* Seed for WAAS Lobby */
    uint256 internal constant WAAS_LOBBY_SEED_HEARTS = 1e9 * HEARTS_PER_HEX;

    /* Start of claim phase */
    uint256 internal constant PRE_CLAIM_DAYS = 1;
    uint256 internal constant CLAIM_PHASE_START_DAY = PRE_CLAIM_DAYS;

    /* Length of claim phase */
    uint256 private constant CLAIM_PHASE_WEEKS = 50;
    uint256 internal constant CLAIM_PHASE_DAYS = CLAIM_PHASE_WEEKS * 7;

    /* End of claim phase */
    uint256 internal constant CLAIM_PHASE_END_DAY = CLAIM_PHASE_START_DAY + CLAIM_PHASE_DAYS;

    /* Number of words to hold 1 bit for each transform lobby day */
    uint256 internal constant XF_LOBBY_DAY_WORDS = (CLAIM_PHASE_END_DAY + 255) >> 8;

    /* WAAS lump day */
    uint256 internal constant WAAS_LUMP_DAY = CLAIM_PHASE_END_DAY + 1;

    /* Root hash of the UTXO Merkle tree */
    bytes32 internal constant MERKLE_TREE_ROOT = 0x6c78104d5710f8ba6e080ada5997c3d95a3aff00041f78bbfae0816d6beaced8;

    /* Size of a Satoshi total uint */
    uint256 internal constant SATOSHI_UINT_SIZE = 51;
    uint256 internal constant SATOSHI_UINT_MASK = (1 << SATOSHI_UINT_SIZE) - 1;

    /* Total Satoshis from all BTC addresses in UTXO snapshot */
    uint256 internal constant FULL_SATOSHIS_TOTAL = 53183860816766;

    /* Total Satoshis from supported BTC addresses in UTXO snapshot after applying Silly Whale */
    uint256 internal constant CLAIMABLE_SATOSHIS_TOTAL = 21281768913380;

    /* Number of claimable BTC addresses in UTXO snapshot */
    uint256 internal constant CLAIMABLE_BTC_ADDR_COUNT = 1000;

    /* Largest BTC address Satoshis balance in UTXO snapshot (sanity check) */
    uint256 internal constant MAX_BTC_ADDR_BALANCE_SATOSHIS = 988025376134;

    /* Percentage of total claimed Hearts that will be auto-staked from a claim */
    uint256 internal constant AUTO_STAKE_CLAIM_PERCENT = 90;

    /* Stake timing parameters */
    uint256 internal constant MIN_STAKE_DAYS = 1;
    uint256 internal constant MIN_AUTO_STAKE_DAYS = 350;

    uint256 private constant MAX_STAKE_WEEKS = 50 * 52; // Approx 50 years
    uint256 internal constant MAX_STAKE_DAYS = MAX_STAKE_WEEKS * 7;

    uint256 internal constant EARLY_PENALTY_MIN_DAYS = 90;

    uint256 private constant LATE_PENALTY_GRACE_WEEKS = 2;
    uint256 internal constant LATE_PENALTY_GRACE_DAYS = LATE_PENALTY_GRACE_WEEKS * 7;

    uint256 private constant LATE_PENALTY_SCALE_WEEKS = 100;
    uint256 internal constant LATE_PENALTY_SCALE_DAYS = LATE_PENALTY_SCALE_WEEKS * 7;

    /* Stake shares Longer Pays Better bonus constants used by _calcStakeBonusHearts() */
    uint256 private constant LPB_BONUS_PERCENT = 20;
    uint256 private constant LPB_BONUS_CAP_PERCENT = 200;
    uint256 internal constant LPB = 364 * 100 / LPB_BONUS_PERCENT;
    uint256 internal constant LPB_CAP_DAYS = LPB * LPB_BONUS_CAP_PERCENT / 100;

    /* Stake shares Bigger Pays Better bonus constants used by _calcStakeBonusHearts() */
    uint256 private constant BPB_BONUS_PERCENT = 10;
    uint256 private constant BPB_CAP_HEX = 150 * 1e6;
    uint256 internal constant BPB_CAP_HEARTS = BPB_CAP_HEX * HEARTS_PER_HEX;
    uint256 internal constant BPB = BPB_CAP_HEARTS * 100 / BPB_BONUS_PERCENT;

    /* Share rate is scaled to increase precision */
    uint256 internal constant SHARE_RATE_SCALE = 1e5;

    /* Constants for preparing the claim message text */
    uint8 internal constant ETH_ADDRESS_BYTE_LEN = 20;
    uint8 internal constant ETH_ADDRESS_HEX_LEN = ETH_ADDRESS_BYTE_LEN * 2;

    uint8 internal constant CLAIM_PARAM_HASH_BYTE_LEN = 8;
    uint8 internal constant CLAIM_PARAM_HASH_HEX_LEN = CLAIM_PARAM_HASH_BYTE_LEN * 2;

    uint8 internal constant BITCOIN_SIG_PREFIX_LEN = 24;
    bytes24 internal constant BITCOIN_SIG_PREFIX_STR = "Bitcoin Signed Message:\n";

    bytes internal constant STD_CLAIM_PREFIX_STR = "Claim_HEX_to_0x";
    bytes internal constant OLD_CLAIM_PREFIX_STR = "Claim_BitcoinHEX_to_0x";

    bytes16 internal constant HEX_DIGITS = "0123456789abcdef";

    /* Claim flags passed to claimBtcAddress()  */
    uint8 internal constant CLAIM_FLAG_MSG_PREFIX_OLD = 1 << 0;
    uint8 internal constant CLAIM_FLAG_BTC_ADDR_COMPRESSED = 1 << 1;
    uint8 internal constant CLAIM_FLAG_BTC_ADDR_P2WPKH_IN_P2SH = 1 << 2;
    uint8 internal constant CLAIM_FLAG_ETH_ADDR_LOWERCASE = 1 << 3;

    /* Globals expanded for memory (except _latestStakeId) and compact for storage */
    struct GlobalsCache {
        // 1
        uint256 _lockedHeartsTotal;
        uint256 _nextStakeSharesTotal;
        uint256 _shareRate;
        uint256 _stakePenaltyPool;
        // 2
        uint256 _daysStored;
        uint256 _stakeSharesTotal;
        uint40 _latestStakeId;
        uint256 _unclaimedSatoshisTotal;
        uint256 _claimedSatoshisTotal;
        uint256 _claimedBtcAddrCount;
        //
        uint256 _currentDay;
    }

    struct GlobalsStore {
        // 1
        uint72 lockedHeartsTotal;
        uint72 nextStakeSharesTotal;
        uint40 shareRate;
        uint72 stakePenaltyPool;
        // 2
        uint16 daysStored;
        uint72 stakeSharesTotal;
        uint40 latestStakeId;
        uint128 claimsValues;
    }

    GlobalsStore public globals;

    /* Claimed BTC addresses */
    mapping(bytes20 => bool) public claimedBtcAddresses;

    /* Daily data */
    struct DailyDataStore {
        uint72 dayPayoutTotal;
        uint72 dayStakeSharesTotal;
        uint56 dayUnclaimedSatoshisTotal;
    }

    mapping(uint256 => DailyDataStore) public dailyData;

    /* Stake expanded for memory (except _stakeId) and compact for storage */
    struct StakeCache {
        uint40 _stakeId;
        uint256 _stakedHearts;
        uint256 _stakeShares;
        uint256 _pooledDay;
        uint256 _stakedDays;
        uint256 _unpooledDay;
        bool _isAutoStake;
    }

    struct StakeStore {
        uint40 stakeId;
        uint72 stakedHearts;
        uint72 stakeShares;
        uint16 pooledDay;
        uint16 stakedDays;
        uint16 unpooledDay;
        bool isAutoStake;
    }

    mapping(address => StakeStore[]) public staked;

    /* Temporary state for calculating daily rounds */
    struct RoundState {
        uint256 _allocSupplyCached;
        uint256 _mintOriginBatch;
        uint256 _payoutTotal;
    }

    struct XfLobbyEntryStore {
        uint96 rawAmount;
        address referrerAddr;
    }

    struct XfLobbyQueueStore {
        uint40 headIndex;
        uint40 tailIndex;
        mapping(uint256 => XfLobbyEntryStore) entries;
    }

    mapping(uint256 => uint256) public xfLobby;
    mapping(uint256 => mapping(address => XfLobbyQueueStore)) public xfLobbyMembers;

    /**
     * @dev PUBLIC FACING: Optionally update daily data for a smaller
     * range to reduce gas cost for a subsequent operation
     * @param beforeDay Only update days before this day number (optional; 0 for current day)
     */
    function storeDailyDataBefore(uint256 beforeDay)
        external
    {
        GlobalsCache memory g;
        GlobalsCache memory gSnapshot;
        _loadGlobals(g, gSnapshot);

        /* Skip pre-claim period */
        require(g._currentDay > CLAIM_PHASE_START_DAY, "HEX: Too early");

        if (beforeDay != 0) {
            require(beforeDay <= g._currentDay, "HEX: beforeDay cannot be in the future");

            _storeDailyDataBefore(g, beforeDay);
        } else {
            /* Default to updating before current day */
            _storeDailyDataBefore(g, g._currentDay);
        }

        _syncGlobals(g, gSnapshot);
    }

    /**
     * @dev PUBLIC FACING: ERC20 totalSupply() is the circulating supply and does not include any
     * staked Hearts. allocatedSupply() includes both.
     * @return Allocated Supply in Hearts
     */
    function allocatedSupply()
        external
        view
        returns (uint256)
    {
        return totalSupply() + globals.lockedHeartsTotal;
    }

    /**
     * @dev PUBLIC FACING: External helper to return most global info with a single call.
     * Ugly implementation due to limitations of the standard ABI encoder.
     * @return Fixed array of values
     */
    function getGlobalInfo()
        external
        view
        returns (uint256[12] memory)
    {
        uint256 _claimedBtcAddrCount;
        uint256 _claimedSatoshisTotal;
        uint256 _unclaimedSatoshisTotal;

        (_claimedBtcAddrCount, _claimedSatoshisTotal, _unclaimedSatoshisTotal) = _decodeClaimsValues(
            globals.claimsValues
        );

        return [
            // 1
            globals.lockedHeartsTotal,
            globals.nextStakeSharesTotal,
            globals.shareRate,
            globals.stakePenaltyPool,
            // 2
            globals.daysStored,
            globals.stakeSharesTotal,
            globals.latestStakeId,
            _unclaimedSatoshisTotal,
            _claimedSatoshisTotal,
            _claimedBtcAddrCount,
            //
            _getCurrentDay(),
            totalSupply()
        ];
    }

    /**
     * @dev PUBLIC FACING: External helper to return multiple values of daily data with
     * a single call. Ugly implementation due to limitations of the standard ABI encoder.
     * @param beginDay First day of data range
     * @param endDay Last day (non-inclusive) of data range
     * @return Fixed array of packed values
     */
    function getDailyDataRange(uint256 beginDay, uint256 endDay)
        external
        view
        returns (uint256[] memory list)
    {
        require(beginDay < endDay && endDay <= globals.daysStored, "HEX: range invalid");

        list = new uint256[](endDay - beginDay);

        uint256 src = beginDay;
        uint256 dst = 0;
        do {
            uint256 v1 = uint256(dailyData[src].dayPayoutTotal);
            uint256 v2 = uint256(dailyData[src].dayStakeSharesTotal) << 80;
            uint256 v3 = uint256(dailyData[src].dayUnclaimedSatoshisTotal) << 160;

            list[dst++] = v1 | v2 | v3;
        } while (++src < endDay);

        return list;
    }

    /**
     * @dev PUBLIC FACING: External helper for the current day number since launch time
     * @return Current day number (zero-based)
     */
    function getCurrentDay()
        external
        view
        returns (uint256)
    {
        return _getCurrentDay();
    }

    function _getCurrentDay()
        internal
        view
        returns (uint256)
    {
        return (block.timestamp - LAUNCH_TIME) / 1 days;
    }

    function _encodeClaimsValues(
        uint256 _claimedBtcAddrCount,
        uint256 _claimedSatoshisTotal,
        uint256 _unclaimedSatoshisTotal
    )
        internal
        pure
        returns (uint128)
    {
        uint256 v = _claimedBtcAddrCount << (SATOSHI_UINT_SIZE * 2);
        v |= _claimedSatoshisTotal << SATOSHI_UINT_SIZE;
        v |= _unclaimedSatoshisTotal;

        return uint128(v);
    }

    function _decodeClaimsValues(uint128 v)
        internal
        pure
        returns (uint256 _claimedBtcAddrCount, uint256 _claimedSatoshisTotal, uint256 _unclaimedSatoshisTotal)
    {
        _claimedBtcAddrCount = v >> (SATOSHI_UINT_SIZE * 2);
        _claimedSatoshisTotal = (v >> SATOSHI_UINT_SIZE) & SATOSHI_UINT_MASK;
        _unclaimedSatoshisTotal = v & SATOSHI_UINT_MASK;

        return (_claimedBtcAddrCount, _claimedSatoshisTotal, _unclaimedSatoshisTotal);
    }

    function _loadGlobals(GlobalsCache memory g, GlobalsCache memory gSnapshot)
        internal
        view
    {
        // 1
        g._lockedHeartsTotal = globals.lockedHeartsTotal;
        g._nextStakeSharesTotal = globals.nextStakeSharesTotal;
        g._shareRate = globals.shareRate;
        g._stakePenaltyPool = globals.stakePenaltyPool;
        // 2
        g._daysStored = globals.daysStored;
        g._stakeSharesTotal = globals.stakeSharesTotal;
        g._latestStakeId = globals.latestStakeId;
        (g._claimedBtcAddrCount, g._claimedSatoshisTotal, g._unclaimedSatoshisTotal) = _decodeClaimsValues(
            globals.claimsValues
        );
        //
        g._currentDay = _getCurrentDay();

        _snapshotGlobalsCache(g, gSnapshot);
    }

    function _snapshotGlobalsCache(GlobalsCache memory g, GlobalsCache memory gSnapshot)
        internal
        pure
    {
        // 1
        gSnapshot._lockedHeartsTotal = g._lockedHeartsTotal;
        gSnapshot._nextStakeSharesTotal = g._nextStakeSharesTotal;
        gSnapshot._shareRate = g._shareRate;
        gSnapshot._stakePenaltyPool = g._stakePenaltyPool;
        // 2
        gSnapshot._daysStored = g._daysStored;
        gSnapshot._stakeSharesTotal = g._stakeSharesTotal;
        gSnapshot._latestStakeId = g._latestStakeId;
        gSnapshot._unclaimedSatoshisTotal = g._unclaimedSatoshisTotal;
        gSnapshot._claimedSatoshisTotal = g._claimedSatoshisTotal;
        gSnapshot._claimedBtcAddrCount = g._claimedBtcAddrCount;
    }

    function _syncGlobals(GlobalsCache memory g, GlobalsCache memory gSnapshot)
        internal
    {
        if (g._lockedHeartsTotal != gSnapshot._lockedHeartsTotal
            || g._nextStakeSharesTotal != gSnapshot._nextStakeSharesTotal
            || g._shareRate != gSnapshot._shareRate
            || g._stakePenaltyPool != gSnapshot._stakePenaltyPool) {
            // 1
            globals.lockedHeartsTotal = uint72(g._lockedHeartsTotal);
            globals.nextStakeSharesTotal = uint72(g._nextStakeSharesTotal);
            globals.shareRate = uint40(g._shareRate);
            globals.stakePenaltyPool = uint72(g._stakePenaltyPool);
        }
        if (g._daysStored != gSnapshot._daysStored
            || g._stakeSharesTotal != gSnapshot._stakeSharesTotal
            || g._latestStakeId != gSnapshot._latestStakeId
            || g._unclaimedSatoshisTotal != gSnapshot._unclaimedSatoshisTotal
            || g._claimedSatoshisTotal != gSnapshot._claimedSatoshisTotal
            || g._claimedBtcAddrCount != gSnapshot._claimedBtcAddrCount) {
            // 2
            globals.daysStored = uint16(g._daysStored);
            globals.stakeSharesTotal = uint72(g._stakeSharesTotal);
            globals.latestStakeId = g._latestStakeId;
            globals.claimsValues = _encodeClaimsValues(
                g._claimedBtcAddrCount,
                g._claimedSatoshisTotal,
                g._unclaimedSatoshisTotal
            );
        }
    }

    function _loadStake(StakeStore storage stRef, uint40 stakeIdParam, StakeCache memory st)
        internal
        view
    {
        /* Ensure caller's stakeIndex is still current */
        require(stakeIdParam == stRef.stakeId, "HEX: stakeIdParam not in stake");

        st._stakeId = stRef.stakeId;
        st._stakedHearts = stRef.stakedHearts;
        st._stakeShares = stRef.stakeShares;
        st._pooledDay = stRef.pooledDay;
        st._stakedDays = stRef.stakedDays;
        st._unpooledDay = stRef.unpooledDay;
        st._isAutoStake = stRef.isAutoStake;
    }

    function _updateStake(StakeStore storage stRef, StakeCache memory st)
        internal
    {
        stRef.stakeId = st._stakeId;
        stRef.stakedHearts = uint72(st._stakedHearts);
        stRef.stakeShares = uint72(st._stakeShares);
        stRef.pooledDay = uint16(st._pooledDay);
        stRef.stakedDays = uint16(st._stakedDays);
        stRef.unpooledDay = uint16(st._unpooledDay);
        stRef.isAutoStake = st._isAutoStake;
    }

    function _addStake(
        StakeStore[] storage stakeListRef,
        uint40 newStakeId,
        uint256 newStakedHearts,
        uint256 newStakeShares,
        uint256 newPooledDay,
        uint256 newStakedDays,
        bool newAutoStake
    )
        internal
    {
        stakeListRef.push(
            StakeStore(
                newStakeId,
                uint72(newStakedHearts),
                uint72(newStakeShares),
                uint16(newPooledDay),
                uint16(newStakedDays),
                uint16(0), // unpooledDay
                newAutoStake
            )
        );
    }

    /**
     * @dev Efficiently delete from an unordered array by moving the last element
     * to the "hole" and reducing the array length. Can change the order of the list
     * and invalidate previously held indexes.
     * @notice stakeListRef length and stakeIndex are already ensured valid in endStake()
     * @param stakeListRef Reference to staked[stakerAddr] array in storage
     * @param stakeIndex Index of the element to delete
     */
    function _removeStakeFromList(StakeStore[] storage stakeListRef, uint256 stakeIndex)
        internal
    {
        uint256 lastIndex = stakeListRef.length - 1;

        /* Skip the copy if element to be removed is already the last element */
        if (stakeIndex != lastIndex) {
            /* Copy last element to the requested element's "hole" */
            stakeListRef[stakeIndex] = stakeListRef[lastIndex];
        }

        /*
            Reduce the array length now that the array is contiguous.
            Surprisingly, 'pop()' uses less gas than 'stakeListRef.length = lastIndex'
        */
        stakeListRef.pop();
    }

    /**
     * @dev Split a penalty 50:50 between origin and stakePenaltyPool
     */
    function _splitPenaltyProceeds(GlobalsCache memory g, uint256 penalty)
        internal
    {
        uint256 splitPenalty = penalty / 2;

        if (splitPenalty != 0) {
            _mint(ORIGIN_ADDR, splitPenalty);
        }

        /* Use the other half of the penalty to account for an odd-numbered penalty */
        splitPenalty = penalty - splitPenalty;
        g._stakePenaltyPool += splitPenalty;
    }

    function _storeDailyDataBefore(GlobalsCache memory g, uint256 beforeDay)
        internal
    {
        if (g._daysStored >= beforeDay) {
            /* Already up-to-date */
            return;
        }

        RoundState memory rs;
        rs._allocSupplyCached = totalSupply() + g._lockedHeartsTotal;

        uint256 day = g._daysStored;

        _calcAndStoreDailyRound(g, rs, day);

        /* Stakes started during this day are added to the pool next day */
        if (g._nextStakeSharesTotal != 0) {
            g._stakeSharesTotal += g._nextStakeSharesTotal;
            g._nextStakeSharesTotal = 0;
        }

        while (++day < beforeDay) {
            _calcAndStoreDailyRound(g, rs, day);
        }

        emit DailyDataUpdate(
            uint40(block.timestamp),
            uint16(day - g._daysStored),
            uint16(day),
            msg.sender
        );
        g._daysStored = day;

        if (rs._mintOriginBatch != 0) {
            _mint(ORIGIN_ADDR, rs._mintOriginBatch);
        }
    }

    /**
     * @dev Estimate the stake payout for an incomplete day
     * @param g Cache of stored globals
     * @param stakeSharesParam Param from stake to calculate bonuses for
     * @param day Day to calculate bonuses for
     * @return Payout in Hearts
     */
    function _estimatePayoutRewardsDay(GlobalsCache memory g, uint256 stakeSharesParam, uint256 day)
        internal
        view
        returns (uint256 payout)
    {
        /* Prevent updating state for this estimation */
        GlobalsCache memory gTmp;
        _snapshotGlobalsCache(g, gTmp);

        RoundState memory rs;
        rs._allocSupplyCached = totalSupply() + g._lockedHeartsTotal;

        _calcDailyRound(gTmp, rs, day);

        /* Stake is not in pool so it must be added to total as if it were */
        gTmp._stakeSharesTotal += stakeSharesParam;

        payout = rs._payoutTotal * stakeSharesParam / gTmp._stakeSharesTotal;

        if (day == WAAS_LUMP_DAY) {
            uint256 waasRound = gTmp._unclaimedSatoshisTotal * HEARTS_PER_SATOSHI * stakeSharesParam / gTmp._stakeSharesTotal;
            payout += waasRound + _calcAdoptionBonus(gTmp, waasRound);
        }

        return payout;
    }

    function _calcAdoptionBonus(GlobalsCache memory g, uint256 payout)
        internal
        pure
        returns (uint256)
    {
        /*
            VIRAL REWARDS: Add adoption percentage bonus to payout

            viral = payout * (claimedBtcAddrCount / CLAIMABLE_BTC_ADDR_COUNT)
        */
        uint256 viral = payout * g._claimedBtcAddrCount / CLAIMABLE_BTC_ADDR_COUNT;

        /*
            CRIT MASS REWARDS: Add adoption percentage bonus to payout

            crit  = payout * (claimedSatoshisTotal / CLAIMABLE_SATOSHIS_TOTAL)
        */
        uint256 crit = payout * g._claimedSatoshisTotal / CLAIMABLE_SATOSHIS_TOTAL;

        return viral + crit;
    }

    function _batchMintOrigin(RoundState memory rs, uint256 amount)
        private
        pure
    {
        rs._mintOriginBatch += amount;
        rs._allocSupplyCached += amount;
    }

    function _calcDailyRound(GlobalsCache memory g, RoundState memory rs, uint256 day)
        private
        pure
    {
        /*
            Calculate payout round

            Inflation of 3.69% inflation per 364 days             (approx 1 year)
            dailyInterestRate   = exp(log(1 + 3.69%)  / 364) - 1
                                = exp(log(1 + 0.0369) / 364) - 1
                                = exp(log(1.0369) / 364) - 1
                                = 0.000099553011616349            (approx)

            payout  = allocSupply * dailyInterestRate
                    = allocSupply / (1 / dailyInterestRate)
                    = allocSupply / (1 / 0.000099553011616349)
                    = allocSupply / 10044.899534066692            (approx)
                    = allocSupply * 10000 / 100448995             (approx)
        */
        rs._payoutTotal = rs._allocSupplyCached * 10000 / 100448995;

        if (day < CLAIM_PHASE_END_DAY) {
            uint256 waasRound = g._unclaimedSatoshisTotal * HEARTS_PER_SATOSHI / CLAIM_PHASE_DAYS;

            _batchMintOrigin(rs, waasRound + _calcAdoptionBonus(g, rs._payoutTotal + waasRound));

            rs._payoutTotal += _calcAdoptionBonus(g, rs._payoutTotal);
        }

        if (g._stakePenaltyPool != 0) {
            rs._payoutTotal += g._stakePenaltyPool;
            g._stakePenaltyPool = 0;
        }
    }

    function _calcAndStoreDailyRound(GlobalsCache memory g, RoundState memory rs, uint256 day)
        private
    {
        _calcDailyRound(g, rs, day);

        dailyData[day].dayPayoutTotal = uint72(rs._payoutTotal);
        dailyData[day].dayStakeSharesTotal = uint72(g._stakeSharesTotal);
        dailyData[day].dayUnclaimedSatoshisTotal = uint56(g._unclaimedSatoshisTotal);
    }
}
