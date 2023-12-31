// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "../implementation/IncentivePool.sol";
import "../interface/IIIncentivePoolAllocation.sol";
import "../interface/IIIncentivePoolReceiver.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../../utils/implementation/SafePct.sol";


enum TopupType{ FACTOROFDAILYAUTHORIZED, ALLAUTHORIZED }

/**
* @notice A struct that defines how request topups will be computed for a reward service.
* @param topupType             The type to signal how the topup amounts are to be calculated.
*                              FACTOROFDAILYAUTHORIZED = Use a factor of last daily authorized to set a
*                              target balance for a reward service to maintain as a reserve for claiming.
*                              ALLAUTHORIZED = Pull enough native tokens to topup reward service contract to hold
*                              all authorized but unrequested rewards.
* @param topupFactorX100       If _topupType == FACTOROFDAILYAUTHORIZED, then this factor (times 100)
*                              is multiplied by last daily authorized incentive to obtain the
*                              maximum balance that a reward service can hold at any given time. If it holds less,
*                              then this max amount is used to compute the request topup required to
*                              bring the reward service contract native token balance up to that amount.
*/
struct TopupConfiguration {
    TopupType topupType;                            // Topup algo type
    uint256 topupFactorX100;                        // Topup factor, times 100, if applicable for type
    bool configured;                                // Flag to indicate whether initially configured
}

/**
 * @title Incentive Pool Reward Services library
 * @notice A library to manage a collection of reward services, their associated totals, and to perform operations
 *  that impact or involve the collection, such as calculating topup amounts across services.
 * @dev There are two concepts that are helpful to understand. A sharing percentage associates an incentive receiver
 *  with a sharing percentage used to calculate percentage of authorized incentive a given reward contract
 *  is entitled to receive for distributing rewards. A reward service is associated to a topup configuration, which
 *  dictates how much native token will be sent for claiming reserves, and it stores totals for a given
 *  incentive receiver.
 **/
library IncentivePoolRewardServices {
    using IncentivePoolRewardServices for RewardService;
    using SafeMath for uint256;
    using SafePct for uint256;

    /**
     * @dev `RewardService` is state structure used by this library to manage
     *   a reward service tracking authorized incentive.
     */
    struct RewardService {
        IIIncentivePoolReceiver incentivePoolReceiver;  // The target rewarding contract
        uint256 authorizedIncentiveWei;                 // Total authorized incentive for this reward service
        uint256 lastDailyAuthorizedIncentiveWei;        // Last daily authorized incentive amount
        uint256 incentivePoolTopupRequestedWei;         // Total incentive topup requested
        uint256 incentivePoolTopupDistributedWei;       // Total incentive topup distributed
    }

    /**
     * @dev `IncentivePoolRewardServicesState` is state structure used by this library to manage
     *   a collection of reward services and associated totals.
     */
    struct IncentivePoolRewardServicesState {
        // Collection of reward services
        RewardService[] rewardServices;
    }

    uint256 internal constant BIPS100 = 1e4;                            // 100% in basis points

    event IncentivePoolRewardServiceDailyAuthorizedIncentiveComputed(
        IIIncentivePoolReceiver incentivePoolReceiver, uint256 amountWei);
    event IncentivePoolRewardServiceTopupComputed(
        IIIncentivePoolReceiver incentivePoolReceiver, uint256 amountWei);
    event IncentivePoolRewardServiceTopupRequestReceived(
        IIIncentivePoolReceiver incentivePoolReceiver, uint256 amountWei);

    /**
     * @notice For all sharing percentages, compute authorized daily incentive for current cycle
     *  and then allocate it across associated incentive pool receivers according to their sharing percentages,
     *  updating reward service totals along the way. Finally,
     *  set the daily authorized incentive for the given incentive pool receiver.
     * @param _totalRecognizedIncentiveWei The total recognized incentive across all time slots.
     * @param _totalAuthorizedIncentiveWei The total authorized incentive across all time slots.
     * @param _periodsRemaining The number of periods remaining in the current time slot.
     * @param _sharingPercentages An array of incentive sharing percentages.
     * @return _amountAuthorizedWei The incentive authorized for this cycle.
     * @dev This method requires totals across all time slots so as to continually calculate
     *   the amount remaining to be authorized regardless of timing slippage between time slots should it
     *   occur.
     */
    function authorizeDailyIncentive(
        IncentivePoolRewardServicesState storage _self,
        uint256 _totalRecognizedIncentiveWei,
        uint256 _totalAuthorizedIncentiveWei,
        uint256 _periodsRemaining,
        SharingPercentage[] memory _sharingPercentages
    )
        internal
        returns(uint256 _amountAuthorizedWei)
    {
        // If there are no sharing percentages, then there is nothing to authorize.
        if (_sharingPercentages.length == 0) {
            _amountAuthorizedWei = 0;
            return _amountAuthorizedWei;
        }

        // Compute amount to allocate
        uint256 amountToAuthorizeRemainingWei = _totalRecognizedIncentiveWei
            .sub(_totalAuthorizedIncentiveWei)
            .div(_periodsRemaining);
        // Set up return value with amount authorized
        _amountAuthorizedWei = amountToAuthorizeRemainingWei;
        // Start with total bips in denominator
        uint256 divisorRemaining = BIPS100;
        // Loop over sharing percentages
        for (uint256 i = 0; i < _sharingPercentages.length; i++) {
            // Compute the amount to authorize for a given service
            uint256 toAuthorizeWei = amountToAuthorizeRemainingWei.mulDiv(
                _sharingPercentages[i].percentBips,
                divisorRemaining
            );
            // Reduce the numerator by amount just computed
            amountToAuthorizeRemainingWei = amountToAuthorizeRemainingWei.sub(toAuthorizeWei);
            // Reduce the divisor by the bips just allocated
            divisorRemaining = divisorRemaining.sub(_sharingPercentages[i].percentBips);
            // Try to find a matching reward service for the given sharing percentage.
            // New sharing percentages can be added at any time. And if one gets removed,
            // we don't remove that reward service for a given time slot, since its total still
            // remains applicable.
            ( bool found, uint256 rewardServiceIndex ) =
                findRewardService(_self, _sharingPercentages[i].incentivePoolReceiver);
            if (found) {
                // Get the existing reward service
                RewardService storage rewardService = _self.rewardServices[rewardServiceIndex];
                // Accumulate the amount authorized for the service
                rewardService.addAuthorizedIncentive(toAuthorizeWei);
            } else {
                // Initialize a new reward service
                RewardService storage rewardService =
                    _self.rewardServices.push();
                rewardService.initialize(_sharingPercentages[i].incentivePoolReceiver);
                // Accumulate the amount authorized for the service
                rewardService.addAuthorizedIncentive(toAuthorizeWei);
            }
            // Signal the incentive pool receiver of the reward service (the actual rewarding contract)
            // with amount just authorized.
            _sharingPercentages[i].incentivePoolReceiver.setDailyAuthorizedIncentive(toAuthorizeWei);

            emit IncentivePoolRewardServiceDailyAuthorizedIncentiveComputed(
                _sharingPercentages[i].incentivePoolReceiver,
                toAuthorizeWei);
        }
    }

    /**
     * @notice Given topup configurations as maintained by an instantiated IncentivePool contract, compute
     *   the topup requests needed to topup reward contracts with native token reserves to satisfy claim requests.
     * @param _incentivePool The IncentivePool contract holding the topup configurations.
     * @param _maxPullRequestWei Max amount that can be pulled from treasury contract
     * @return _topupRequestWei The topup request to distribute native tokens across reward services for this cycle.
     */
    function computeTopupRequest(
        IncentivePoolRewardServicesState storage _self,
        IncentivePool _incentivePool,
        uint256 _maxPullRequestWei
    )
        internal
        returns (uint256 _topupRequestWei)
    {
        uint256[] memory topupRequests = new uint256[](_self.rewardServices.length);
        for (uint256 i = 0; i < _self.rewardServices.length; i++) {
            TopupConfiguration memory topupConfiguration =
                _incentivePool.getTopupConfiguration(_self.rewardServices[i].incentivePoolReceiver);
            uint256 topupRequest = _self.rewardServices[i].computeTopupRequest(topupConfiguration);
            topupRequests[i] = topupRequest;
            _topupRequestWei = _topupRequestWei.add(topupRequest);
        }
        if (_topupRequestWei > _maxPullRequestWei) { // reduce topup requests proportionally
            uint256 diff = _topupRequestWei - _maxPullRequestWei;
            uint256 topupRequest = _topupRequestWei;
            // Spin through all reward services
            for (uint256 i = 0; i < _self.rewardServices.length; i++) {
                if (topupRequests[i] > 0) {
                    // Decrease topup request for the service
                    uint256 decreaseBy = diff.mulDivRoundUp(topupRequests[i], topupRequest);
                    topupRequest = topupRequest.sub(topupRequests[i]);
                    topupRequests[i] = topupRequests[i].sub(decreaseBy);
                    // Update remaining
                    _topupRequestWei = _topupRequestWei.sub(decreaseBy);
                    diff = diff.sub(decreaseBy);
                    // Finish if topups for all requesting services were reduced
                    if (topupRequest == 0) {
                        break;
                    }
                }
            }
            assert(_topupRequestWei <= _maxPullRequestWei);
        }

        for (uint256 i = 0; i < _self.rewardServices.length; i++) {
            _self.rewardServices[i].incentivePoolTopupRequestedWei =
                _self.rewardServices[i].incentivePoolTopupRequestedWei.add(topupRequests[i]);
            emit IncentivePoolRewardServiceTopupComputed(
                _self.rewardServices[i].incentivePoolReceiver,
                topupRequests[i]);
        }
    }

    /**
     * @notice Receive a topup request of native tokens and disburse amongst requestors.
     * @return _amountPostedWei The total amount of native tokens funded.
     * @dev Assume value is siting in IncentivePool contract waiting to be posted and transmitted.
     *   This function is atomic, so if for some reason not enough native tokens are available, this
     *   function will fail until all topup requests can be satisfied.
     */
    function receiveTopupRequest(
        IncentivePoolRewardServicesState storage _self
    )
        internal
        returns(uint256 _amountPostedWei)
    {
        // Spin through all reward services
        for (uint256 i = 0; i < _self.rewardServices.length; i++) {
            // Get the pending topup for the service
            uint256 pendingTopupWei = _self.rewardServices[i].getPendingTopup();
            // Accumulate topup distributed
            _self.rewardServices[i].addTopupDistributed(pendingTopupWei);
            // Transfer topup to rewarding service contract
            _self.rewardServices[i].incentivePoolReceiver.receiveIncentive{value: pendingTopupWei}();
            // Accumulate amount posted
            _amountPostedWei = _amountPostedWei.add(pendingTopupWei);

            emit IncentivePoolRewardServiceTopupRequestReceived(
                _self.rewardServices[i].incentivePoolReceiver, pendingTopupWei);
        }
    }

    ////////////// REWARD SERVICE HELPER FUNCTIONS ////////////////////////

    /**
     * @notice Initialize a new reward service.
     * @dev Assume service is already instantiated.
     */
    function initialize(
        RewardService storage _self,
        IIIncentivePoolReceiver _incentivePoolReceiver
    )
        internal
    {
        _self.incentivePoolReceiver = _incentivePoolReceiver;
        _self.authorizedIncentiveWei = 0;
        _self.lastDailyAuthorizedIncentiveWei = 0;
        _self.incentivePoolTopupRequestedWei = 0;
        _self.incentivePoolTopupDistributedWei = 0;
    }

    /**
     * @notice Maintain authorized incentive total for service.
     * @param _amountWei Amount to add.
     */
    function addAuthorizedIncentive(RewardService storage _self, uint256 _amountWei) internal {
        _self.authorizedIncentiveWei = _self.authorizedIncentiveWei.add(_amountWei);
        _self.lastDailyAuthorizedIncentiveWei = _amountWei;
    }

    /**
     * @notice Maintain topup native tokens distributed total for service.
     * @param _amountWei Amount to add.
     */
    function addTopupDistributed(RewardService storage _self, uint256 _amountWei) internal {
        _self.incentivePoolTopupDistributedWei = _self.incentivePoolTopupDistributedWei.add(_amountWei);
    }

    /**
     * @notice Given a topup configuration, compute the topup request for the reward contract associated
     *   to the service.
     * @param _topupConfiguration   The topup configuration defining the algo used to compute the topup amount.
     * @return _topupRequestWei     The topup request amount computed.
     */
    function computeTopupRequest(
        RewardService storage _self,
        TopupConfiguration memory _topupConfiguration
    )
        internal view
        returns (uint256 _topupRequestWei)
    {
        // Get the balance of the incentive pool receiver
        uint256 incentivePoolReceiverBalanceWei;
        try _self.incentivePoolReceiver.getExpectedBalance() returns(uint256 expectedBalance) {
            incentivePoolReceiverBalanceWei = expectedBalance;
        } catch {
            incentivePoolReceiverBalanceWei = address(_self.incentivePoolReceiver).balance;
        }
        if (_topupConfiguration.topupType == TopupType.FACTOROFDAILYAUTHORIZED) {
            // Compute a topup request based purely on the given factor, the last daily authorization, and
            // the balance that is sitting in the reward service contract.
            uint256 requestedBalanceWei = _self.lastDailyAuthorizedIncentiveWei
                .mulDiv(_topupConfiguration.topupFactorX100, 100);
            uint256 rawTopupRequestWei = 0;
            // If current balance is less then requested, request some more.
            if (requestedBalanceWei > incentivePoolReceiverBalanceWei) {
                rawTopupRequestWei = requestedBalanceWei.sub(incentivePoolReceiverBalanceWei);
            }
            // Compute what is already pending to be topped up
            uint256 topupPendingWei = getPendingTopup(_self);
            // If what is pending to topup is greater than the raw request, request no more.
            if (topupPendingWei > rawTopupRequestWei) {
                _topupRequestWei = 0;
            } else {
                // Back out any request that is already pending
                _topupRequestWei = rawTopupRequestWei.sub(topupPendingWei);
            }
            // And finally, in any case, topup requested cannot be more than the net of
            // authorized, pending, and received
            uint256 maxTopupRequestWei = _self.authorizedIncentiveWei
                .sub(topupPendingWei)
                .sub(_self.incentivePoolTopupDistributedWei);
            if (_topupRequestWei > maxTopupRequestWei) {
                _topupRequestWei = maxTopupRequestWei;
            }
        } else if (_topupConfiguration.topupType == TopupType.ALLAUTHORIZED) {
            _topupRequestWei = _self.authorizedIncentiveWei
                .sub(_self.incentivePoolTopupRequestedWei);
        } else { // This code is unreachable since TopupType currently has only 2 constructors
            _topupRequestWei = 0;
            assert(false);
        }
    }

    /**
     * @notice Compute a pending topup request.
     * @return _pendingTopupWei The amount pending to be sent.
     */
    function getPendingTopup(
        RewardService storage _self
    )
        internal view
        returns(uint256 _pendingTopupWei)
    {
        return _self.incentivePoolTopupRequestedWei.sub(_self.incentivePoolTopupDistributedWei);
    }

    /**
     * @notice Given an incentive pool receiver, return the index of the associated reward service.
     * @param _incentivePoolReceiver The incentive pool receiver.
     * @return _found   True if the reward service was found.
     * @return _index   The index on the rewardServices array of the found service. Index is undefined
     *   if the reward service was not found.
     */
    function findRewardService(
        IncentivePoolRewardServicesState storage _self,
        IIIncentivePoolReceiver _incentivePoolReceiver
    )
        internal view
        returns(bool _found, uint256 _index)
    {
        // The number of these is expected to be low.
        _found = false;
        for (uint256 i = 0; i < _self.rewardServices.length; i++) {
            if (_self.rewardServices[i].incentivePoolReceiver == _incentivePoolReceiver) {
                _index = i;
                _found = true;
                break;
            }
        }
    }
}
