pragma solidity 0.5.10;

import "./UTXORedeemableToken.sol";

contract TransformableToken is UTXORedeemableToken {
    /**
     * @dev PUBLIC FACING: Join the tranform lobby for the current round
     * @param referrerAddr Eth address of referring user (optional; 0x0 for no referrer)
     */
    function joinXfLobby(address referrerAddr)
        external
        payable
    {
        uint256 joinDay = _getCurrentDay();
        require(joinDay < CLAIM_PHASE_END_DAY, "HEX: WAAS has ended");

        uint256 rawAmount = msg.value;
        require(rawAmount != 0, "HEX: Amount required");

        XfLobbyQueueStore storage qRef = xfLobbyMembers[joinDay][msg.sender];

        uint256 entryIndex = qRef.tailIndex++;

        qRef.entries[entryIndex] = XfLobbyEntryStore(uint96(rawAmount), referrerAddr);

        xfLobby[joinDay] += rawAmount;

        _emitJoin(joinDay, entryIndex, rawAmount, referrerAddr);
    }

    /**
     * @dev PUBLIC FACING: Leave the transform lobby after the round is complete
     * @param joinDay Day number when the member joined
     * @param count Number of queued-joins to leave (optional; 0 for all)
     */
    function leaveXfLobby(uint256 joinDay, uint256 count)
        external
    {
        require(joinDay < _getCurrentDay(), "HEX: Round is not complete");

        XfLobbyQueueStore storage qRef = xfLobbyMembers[joinDay][msg.sender];

        uint256 headIndex = qRef.headIndex;
        uint256 endIndex;

        if (count != 0) {
            require(count <= qRef.tailIndex - headIndex, "HEX: count invalid");
            endIndex = headIndex + count;
        } else {
            endIndex = qRef.tailIndex;
            require(headIndex < endIndex, "HEX: count invalid");
        }

        uint256 waasLobby = getWaasLobby(joinDay);
        uint256 _xfLobby = xfLobby[joinDay];
        uint256 totalXfAmount = 0;
        uint256 originBonusHearts = 0;

        do {
            uint256 rawAmount = qRef.entries[headIndex].rawAmount;
            address referrerAddr = qRef.entries[headIndex].referrerAddr;

            delete qRef.entries[headIndex];

            uint256 xfAmount = waasLobby * rawAmount / _xfLobby;

            if (referrerAddr == address(0)) {
                /* No referrer */
                _emitLeave(joinDay, headIndex, xfAmount, referrerAddr);
            } else {
                /* Referral bonus of 10% of xfAmount to member */
                uint256 referralBonusHearts = xfAmount / 10;

                xfAmount += referralBonusHearts;

                /* Then a cumulative referrer bonus of 20% to referrer */
                uint256 referrerBonusHearts = xfAmount / 5;

                if (referrerAddr == msg.sender) {
                    /* Self-referred */
                    xfAmount += referrerBonusHearts;
                    _emitLeave(joinDay, headIndex, xfAmount, referrerAddr);
                } else {
                    /* Referred by different address */
                    _emitLeave(joinDay, headIndex, xfAmount, referrerAddr);
                    _mint(referrerAddr, referrerBonusHearts);
                }
                originBonusHearts += referralBonusHearts + referrerBonusHearts;
            }

            totalXfAmount += xfAmount;
        } while (++headIndex < endIndex);

        qRef.headIndex = uint40(headIndex);

        if (originBonusHearts != 0) {
            _mint(ORIGIN_ADDR, originBonusHearts);
        }
        if (totalXfAmount != 0) {
            _mint(msg.sender, totalXfAmount);
        }
    }

    /**
     * @dev PUBLIC FACING: Release any value that has been sent to the contract
     */
    function flush()
        external
    {
        require(address(this).balance != 0, "HEX: No value");

        FLUSH_ADDR.transfer(address(this).balance);
    }

    /**
     * @dev PUBLIC FACING: External helper to return multiple values of xfLobby[] with
     * a single call
     * @param beginDay First day of data range
     * @param endDay Last day (non-inclusive) of data range
     * @return Fixed array of values
     */
    function getXfLobbyRange(uint256 beginDay, uint256 endDay)
        external
        view
        returns (uint256[] memory list)
    {
        require(
            beginDay < endDay
                && endDay <= CLAIM_PHASE_END_DAY
                && endDay <= _getCurrentDay(),
            "HEX: invalid range"
        );

        list = new uint256[](endDay - beginDay);

        uint256 src = beginDay;
        uint256 dst = 0;
        do {
            list[dst++] = uint256(xfLobby[src++]);
        } while (src < endDay);

        return list;
    }

    /**
     * @dev PUBLIC FACING: Return a current lobby member queue entry.
     * Only needed due to limitations of the standard ABI encoder.
     * @param memberAddr Ethereum address of the lobby member
     * @param entryId 49 bit compound value. Top 9 bits: joinDay, Bottom 40 bits: entryIndex
     * @return 1: Raw amount that was joined with; 2: Referring Eth addr (optional; 0x0 for no referrer)
     */
    function getXfLobbyEntry(address memberAddr, uint256 entryId)
        external
        view
        returns (uint256 rawAmount, address referrerAddr)
    {
        uint256 joinDay = entryId >> XF_LOBBY_ENTRY_INDEX_SIZE;
        uint256 entryIndex = entryId & XF_LOBBY_ENTRY_INDEX_MASK;

        XfLobbyEntryStore storage entry = xfLobbyMembers[joinDay][memberAddr].entries[entryIndex];

        require(entry.rawAmount != 0, "HEX: Param invalid");

        return (entry.rawAmount, entry.referrerAddr);
    }

    /**
     * @dev PUBLIC FACING: Return the lobby days that a user is in with a single call
     * @param memberAddr Ethereum address of the user
     * @return Bit vector of lobby day numbers
     */
    function getXfLobbyPendingDays(address memberAddr)
        external
        view
        returns (uint256[XF_LOBBY_DAY_WORDS] memory words)
    {
        uint256 day = _getCurrentDay() + 1;

        if (day > CLAIM_PHASE_END_DAY) {
            day = CLAIM_PHASE_END_DAY;
        }

        while (day-- != 0) {
            if (xfLobbyMembers[day][memberAddr].tailIndex > xfLobbyMembers[day][memberAddr].headIndex) {
                words[day >> 8] |= 1 << (day & 255);
            }
        }

        return words;
    }

    function getWaasLobby(uint256 joinDay)
        private
        returns (uint256 waasLobby)
    {
        if (joinDay >= CLAIM_PHASE_START_DAY) {
            GlobalsCache memory g;
            GlobalsCache memory gSnapshot;
            _loadGlobals(g, gSnapshot);

            _storeDailyDataBefore(g, g._currentDay);

            uint256 unclaimed = dailyData[joinDay].dayUnclaimedSatoshisTotal;
            waasLobby = unclaimed * HEARTS_PER_SATOSHI / CLAIM_PHASE_DAYS;

            _syncGlobals(g, gSnapshot);
        } else {
            waasLobby = WAAS_LOBBY_SEED_HEARTS;
        }
        return waasLobby;
    }

    function _emitJoin(uint256 joinDay, uint256 entryIndex, uint256 rawAmount, address referrerAddr)
        private
    {
        emit JoinXfLobby(
            uint40(block.timestamp),
            msg.sender,
            (joinDay << XF_LOBBY_ENTRY_INDEX_SIZE) | entryIndex,
            rawAmount,
            referrerAddr
        );
    }

    function _emitLeave(uint256 joinDay, uint256 entryIndex, uint256 xfAmount, address referrerAddr)
        private
    {
        emit LeaveXfLobby(
            uint40(block.timestamp),
            msg.sender,
            (joinDay << XF_LOBBY_ENTRY_INDEX_SIZE) | entryIndex,
            xfAmount,
            referrerAddr
        );
    }
}
