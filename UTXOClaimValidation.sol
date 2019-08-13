pragma solidity 0.5.10;

import "./StakeableToken.sol";
import "../node_modules/openzeppelin-solidity/contracts/cryptography/MerkleProof.sol";

contract UTXOClaimValidation is StakeableToken {
    /**
     * @dev PUBLIC FACING: Verify a BTC address and balance are unclaimed and part of the Merkle tree
     * @param btcAddr Bitcoin address (binary; no base58-check encoding)
     * @param rawSatoshis Raw BTC address balance in Satoshis
     * @param proof Merkle tree proof
     * @return True if can be claimed
     */
    function canClaimBtcAddress(bytes20 btcAddr, uint256 rawSatoshis, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        uint256 currentDay = _getCurrentDay();

        require(currentDay >= CLAIM_PHASE_START_DAY, "HEX: Claim phase has not yet started");
        require(currentDay < CLAIM_PHASE_END_DAY, "HEX: Claim phase has ended");

        /* Don't need to check Merkle proof if UTXO BTC address has already been claimed    */
        if (claimedBtcAddresses[btcAddr]) {
            return false;
        }

        /* Verify the Merkle tree proof */
        return _btcAddressIsValid(btcAddr, rawSatoshis, proof);
    }

    /**
     * @dev PUBLIC FACING: Verify a BTC address and balance are part of the Merkle tree
     * @param btcAddr Bitcoin address (binary; no base58-check encoding)
     * @param rawSatoshis Raw BTC address balance in Satoshis
     * @param proof Merkle tree proof
     * @return True if valid
     */
    function btcAddressIsValid(bytes20 btcAddr, uint256 rawSatoshis, bytes32[] calldata proof)
        external
        pure
        returns (bool)
    {
        return _btcAddressIsValid(btcAddr, rawSatoshis, proof);
    }

    /**
     * @dev PUBLIC FACING: Verify a Merkle proof using the UTXO Merkle tree
     * @param merkleLeaf Leaf asserted to be present in the Merkle tree
     * @param proof Generated Merkle tree proof
     * @return True if valid
     */
    function merkleProofIsValid(bytes32 merkleLeaf, bytes32[] calldata proof)
        external
        pure
        returns (bool)
    {
        return _merkleProofIsValid(merkleLeaf, proof);
    }

    /**
     * @dev PUBLIC FACING: Verify that a Bitcoin signature matches the claim message containing
     * the Ethereum address and claim param hash
     * @param claimToAddr Eth address within the signed claim message
     * @param claimParamHash Param hash within the signed claim message
     * @param pubKeyX First  half of uncompressed ECDSA public key
     * @param pubKeyY Second half of uncompressed ECDSA public key
     * @param claimFlags Claim flags specifying address and message formats
     * @param v v parameter of ECDSA signature
     * @param r r parameter of ECDSA signature
     * @param s s parameter of ECDSA signature
     * @return True if matching
     */
    function signatureMatchesClaim(
        address claimToAddr,
        bytes32 claimParamHash,
        bytes32 pubKeyX,
        bytes32 pubKeyY,
        uint8 claimFlags,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        public
        pure
        returns (bool)
    {
        require(v >= 27 && v <= 30, "HEX: v invalid");

        /*
            ecrecover() returns an Eth address rather than a public key, so
            we must do the same to compare.
        */
        address pubKeyEthAddr = pubKeyToEthAddress(pubKeyX, pubKeyY);

        /* Create and hash the claim message text */
        bytes32 messageHash = _hash256(
            _createClaimMessage(claimToAddr, claimParamHash, claimFlags)
        );

        /* Verify the public key */
        return ecrecover(messageHash, v, r, s) == pubKeyEthAddr;
    }

    /**
     * @dev PUBLIC FACING: Derive an Ethereum address from an ECDSA public key
     * @param pubKeyX First  half of uncompressed ECDSA public key
     * @param pubKeyY Second half of uncompressed ECDSA public key
     * @return Derived Ethereum address
     */
    function pubKeyToEthAddress(bytes32 pubKeyX, bytes32 pubKeyY)
        public
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(pubKeyX, pubKeyY)))));
    }

    /**
     * @dev PUBLIC FACING: Derive a Bitcoin address from an ECDSA public key
     * @param pubKeyX First  half of uncompressed ECDSA public key
     * @param pubKeyY Second half of uncompressed ECDSA public key
     * @param claimFlags Claim flags specifying address and message formats
     * @return Derived Bitcoin address (binary; no base58-check encoding)
     */
    function pubKeyToBtcAddress(bytes32 pubKeyX, bytes32 pubKeyY, uint8 claimFlags)
        public
        pure
        returns (bytes20)
    {
        /*
            Helpful references:
             - https://en.bitcoin.it/wiki/Technical_background_of_version_1_Bitcoin_addresses
             - https://github.com/cryptocoinjs/ecurve/blob/master/lib/point.js
        */
        uint8 startingByte;
        bytes memory pubKey;

        if ((claimFlags & CLAIM_FLAG_BTC_ADDR_COMPRESSED) != 0) {
            /* Compressed public key format */
            startingByte = (pubKeyY[31] & 0x01) == 0 ? 0x02 : 0x03;
            pubKey = abi.encodePacked(startingByte, pubKeyX);
        } else {
            /* Uncompressed public key format */
            startingByte = 0x04;
            pubKey = abi.encodePacked(startingByte, pubKeyX, pubKeyY);
        }

        bytes20 pubKeyHash = _hash160(pubKey);
        if ((claimFlags & CLAIM_FLAG_BTC_ADDR_P2WPKH_IN_P2SH) != 0) {
            return _hash160(abi.encodePacked(hex"0014", pubKeyHash));
        }
        return pubKeyHash;
    }

    /**
     * @dev Verify a BTC address and balance are part of the Merkle tree
     * @param btcAddr Bitcoin address (binary; no base58-check encoding)
     * @param rawSatoshis Raw BTC address balance in Satoshis
     * @param proof Merkle tree proof
     * @return True if valid
     */
    function _btcAddressIsValid(bytes20 btcAddr, uint256 rawSatoshis, bytes32[] memory proof)
        internal
        pure
        returns (bool)
    {
        /* Calculate the 32 byte Merkle leaf associated with this BTC address and balance */
        bytes32 merkleLeaf = bytes32(btcAddr) | bytes32(rawSatoshis);

        /* Verify the Merkle tree proof */
        return _merkleProofIsValid(merkleLeaf, proof);
    }

    /**
     * @dev Verify a Merkle proof using the UTXO Merkle tree
     * @param merkleLeaf Leaf asserted to be present in the Merkle tree
     * @param proof Generated Merkle tree proof
     * @return True if valid
     */
    function _merkleProofIsValid(bytes32 merkleLeaf, bytes32[] memory proof)
        private
        pure
        returns (bool)
    {
        return MerkleProof.verify(proof, MERKLE_TREE_ROOT, merkleLeaf);
    }

    function _createClaimMessage(address claimToAddr, bytes32 claimParamHash, uint8 claimFlags)
        private
        pure
        returns (bytes memory)
    {
        bytes memory prefixStr = (claimFlags & CLAIM_FLAG_MSG_PREFIX_OLD) != 0
            ? OLD_CLAIM_PREFIX_STR
            : STD_CLAIM_PREFIX_STR;

        bool includeAddrChecksum = (claimFlags & CLAIM_FLAG_ETH_ADDR_LOWERCASE) == 0;

        bytes memory addrStr = _createAddressString(claimToAddr, includeAddrChecksum);

        if (claimParamHash == 0) {
            return abi.encodePacked(
                BITCOIN_SIG_PREFIX_LEN,
                BITCOIN_SIG_PREFIX_STR,
                uint8(prefixStr.length) + ETH_ADDRESS_HEX_LEN,
                prefixStr,
                addrStr
            );
        }

        bytes memory claimParamHashStr = new bytes(CLAIM_PARAM_HASH_HEX_LEN);

        _copyAsHexString(claimParamHashStr, claimParamHash, CLAIM_PARAM_HASH_BYTE_LEN);

        return abi.encodePacked(
            BITCOIN_SIG_PREFIX_LEN,
            BITCOIN_SIG_PREFIX_STR,
            uint8(prefixStr.length) + ETH_ADDRESS_HEX_LEN + 1 + CLAIM_PARAM_HASH_HEX_LEN,
            prefixStr,
            addrStr,
            "_",
            claimParamHashStr
        );
    }

    function _createAddressString(address addr, bool includeAddrChecksum)
        private
        pure
        returns (bytes memory addrStr)
    {
        addrStr = new bytes(ETH_ADDRESS_HEX_LEN);
        _copyAsHexString(addrStr, bytes32(bytes20(addr)), ETH_ADDRESS_BYTE_LEN);

        if (includeAddrChecksum) {
            bytes32 addrStrHash = keccak256(addrStr);

            uint256 offset = 0;

            for (uint256 i = 0; i < ETH_ADDRESS_BYTE_LEN; i++) {
                uint8 b = uint8(addrStrHash[i]);

                _checksumAddressChar(addrStr, offset++, b >> 4);
                _checksumAddressChar(addrStr, offset++, b & 0x0f);
            }
        }

        return addrStr;
    }

    function _copyAsHexString(bytes memory hexStr, bytes32 data, uint256 dataLen)
        private
        pure
    {
        uint256 offset = 0;

        for (uint256 i = 0; i < dataLen; i++) {
            uint8 b = uint8(data[i]);

            hexStr[offset++] = HEX_DIGITS[b >> 4];
            hexStr[offset++] = HEX_DIGITS[b & 0x0f];
        }
    }

    function _checksumAddressChar(bytes memory addrStr, uint256 offset, uint8 hashNybble)
        private
        pure
    {
        bytes1 ch = addrStr[offset];

        if (ch >= "a" && hashNybble >= 8) {
            addrStr[offset] = ch ^ 0x20;
        }
    }

    /**
     * @dev sha256(sha256(data))
     * @param data Data to be hashed
     * @return 32-byte hash
     */
    function _hash256(bytes memory data)
        private
        pure
        returns (bytes32)
    {
        return sha256(abi.encodePacked(sha256(data)));
    }

    /**
     * @dev ripemd160(sha256(data))
     * @param data Data to be hashed
     * @return 20-byte hash
     */
    function _hash160(bytes memory data)
        private
        pure
        returns (bytes20)
    {
        return ripemd160(abi.encodePacked(sha256(data)));
    }
}
