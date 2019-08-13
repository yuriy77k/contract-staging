pragma solidity 0.5.10;

import "./TransformableToken.sol";

contract HEX is TransformableToken {
    constructor()
        public
    {
        /* Initialize global shareRate to 1 */
        globals.shareRate = uint40(1 * SHARE_RATE_SCALE);

        /* Initialize daysStored to skip pre-claim period */
        globals.daysStored = uint16(PRE_CLAIM_DAYS);

        /* Add all Satoshis from UTXO snapshot to contract */
        globals.claimsValues = _encodeClaimsValues(
            0, // _claimedBtcAddrCount
            0, // _claimedSatoshisTotal
            FULL_SATOSHIS_TOTAL // _unclaimedSatoshisTotal
        );
    }

    function() external payable {}
}
