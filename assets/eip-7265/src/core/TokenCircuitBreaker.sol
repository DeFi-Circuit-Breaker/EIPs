// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

import {IERC7265CircuitBreaker} from "../interfaces/IERC7265CircuitBreaker.sol";
import {ITokenCircuitBreaker} from "../interfaces/ITokenCircuitBreaker.sol";
import {ISettlementModule} from "../interfaces/ISettlementModule.sol";

import {CircuitBreaker} from "./CircuitBreaker.sol";

import {Limiter} from "../static/Structs.sol";
import {LimiterLib, LimitStatus} from "../utils/LimiterLib.sol";

contract TokenCircuitBreaker is CircuitBreaker, ITokenCircuitBreaker {
    using LimiterLib for Limiter;
    using SafeERC20 for IERC20;

    error TokenCirtcuitBreaker__NativeTransferFailed();

    // Using address(1) as a proxy for native token (ETH, BNB, etc), address(0) could be problematic
    address public immutable NATIVE_ADDRESS_PROXY = address(1);

    constructor(uint256 _withdrawalPeriod, uint256 _liquidityTickLength)
        CircuitBreaker(_withdrawalPeriod, _liquidityTickLength)
    {}

    /// @dev OWNABLE FUNCTIONS
    
    function registerAsset(
        address _asset,
        uint256 _minLiqRetainedBps,
        uint256 _limitBeginThreshold,
        address _settlementModule
    ) external override onlyOwner {
        bytes32 identifier = keccak256(abi.encodePacked(_asset));
        _addSecurityParameter(identifier, _minLiqRetainedBps, _limitBeginThreshold, _settlementModule);
    }

    function updateAssetParams(
        address _asset,
        uint256 _minLiqRetainedBps,
        uint256 _limitBeginThreshold,
        address _settlementModule
    ) external override onlyOwner {
        bytes32 identifier = keccak256(abi.encodePacked(_asset));
        _updateSecurityParameter(identifier, _minLiqRetainedBps, _limitBeginThreshold, _settlementModule);
    }

    /// @dev TOKEN FUNCTIONS

    function onTokenInflow(address _token, uint256 _amount) external override onlyProtected onlyOperational  {
        _increaseParameter(keccak256(abi.encodePacked(_token)), _amount, _token, 0, new bytes(0));
        emit AssetDeposit(_token, msg.sender, _amount);
    }

    // @dev Funds have been transferred to the circuit breaker before calling onTokenOutflow
    function onTokenOutflow(address _token, uint256 _amount, address _recipient) external override onlyProtected onlyOperational  {
        // compute calldata to call the erc20 contract and transfer funds to _recipient
        bytes memory data = abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), _recipient, _amount);
        
        bool firewallTriggered = _decreaseParameter(keccak256(abi.encodePacked(_token)), _amount, _token, 0, data);
        if (!firewallTriggered) _safeTransferIncludingNative(_token, _recipient, _amount);

        emit AssetDeposit(_token, msg.sender, _amount);
    }

    function onNativeAssetInflow(uint256 _amount) external override onlyProtected onlyOperational {
        _increaseParameter(keccak256(abi.encodePacked(NATIVE_ADDRESS_PROXY)), _amount, address(0), 0, new bytes(0));
        emit AssetDeposit(NATIVE_ADDRESS_PROXY, msg.sender, _amount);
    }

    function onNativeAssetOutflow(address _recipient) external payable override onlyProtected onlyOperational  {
        bool firewallTriggered = _decreaseParameter(
            keccak256(abi.encodePacked(NATIVE_ADDRESS_PROXY)), msg.value, _recipient, msg.value, new bytes(0)
        );

        if (!firewallTriggered) _safeTransferIncludingNative(NATIVE_ADDRESS_PROXY, _recipient, msg.value);

        emit AssetDeposit(NATIVE_ADDRESS_PROXY, msg.sender, msg.value);
    }
    
    function isTokenRateLimited(address token) external view returns (bool) {
        return limiters[keccak256(abi.encodePacked(token))].status() == LimitStatus.Triggered;
    }

    /// @dev INTERNAL FUNCTIONS

    function _onFirewallTrigger(
        Limiter storage limiter,
        address settlementTarget,
        uint256 settlementValue,
        bytes memory settlementPayload
    ) internal override {
        // check if bytes are just 0
        // if not => extract recipient and value from abi encoded bytes data
        // use the data to call _safeTransferIncludingNative

        if (settlementPayload.length > 0) {
            bytes memory dataWithoutSelector = new bytes(settlementPayload.length - 4);
            for (uint i = 0; i < dataWithoutSelector.length; i++) {
                dataWithoutSelector[i] = settlementPayload[i + 4];
            }
            (, uint256 amount) = abi.decode(dataWithoutSelector, (address, uint256));

            _safeTransferIncludingNative(settlementTarget, address(limiter.settlementModule), amount);
        } else {
            _safeTransferIncludingNative(NATIVE_ADDRESS_PROXY, address(limiter.settlementModule), settlementValue);
        }

        limiter.settlementModule.prevent(settlementTarget, settlementValue, settlementPayload);
    }

    function _safeTransferIncludingNative(address _token, address _recipient, uint256 _amount) internal {
        if (_token == NATIVE_ADDRESS_PROXY) {
            (bool success,) = _recipient.call{value: _amount}("");
            if (!success) revert TokenCirtcuitBreaker__NativeTransferFailed();
        } else {
            IERC20(_token).safeTransfer(_recipient, _amount);
        }
    }
}
