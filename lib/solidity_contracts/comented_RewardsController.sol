// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.10;

import {VersionedInitializable} from '@aave/core-v3/contracts/protocol/libraries/aave-upgradeability/VersionedInitializable.sol';
import {SafeCast} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeCast.sol';
import {IScaledBalanceToken} from '@aave/core-v3/contracts/interfaces/IScaledBalanceToken.sol';
import {RewardsDistributor} from './RewardsDistributor.sol';
import {IRewardsController} from './interfaces/IRewardsController.sol';
import {ITransferStrategyBase} from './interfaces/ITransferStrategyBase.sol';
import {RewardsDataTypes} from './libraries/RewardsDataTypes.sol';
import {IEACAggregatorProxy} from '../misc/interfaces/IEACAggregatorProxy.sol';

/**
 * @title RewardsController
 * @notice Abstract contract template to build Distributors contracts for ERC20 rewards to protocol participants
 * @author Aave
 * // @alb As per AAVE v3 docs: This contract is responsible for configuring the different rewards and the claim process.
 * // @alb It also handles the claiming and distribution of rewards
 * // @alb The actual reward calculation and other methods are handled by the `RewardsDistributor` contract
 * // @alb NOTE: Throughout the contract, "asset" refers to an `address` of a token supplied by a user, while
 * // @alb"reward" refers to an `address` of a token that is used as reward
 **/
contract RewardsController is RewardsDistributor, VersionedInitializable, IRewardsController {
  // @alb Do we have libraries to safeguard against overflows? Will we work with felts or with Uint256?
  using SafeCast for uint256;

  uint256 public constant REVISION = 1;

  // This mapping allows whitelisted addresses to claim on behalf of others
  // useful for contracts that hold tokens to be rewarded but don't have any native logic to claim Liquidity Mining rewards
  mapping(address => address) internal _authorizedClaimers;

  // reward => transfer strategy implementation contract
  // The TransferStrategy contract abstracts the logic regarding
  // the source of the reward and how to transfer it to the user.
  mapping(address => ITransferStrategyBase) internal _transferStrategy;

  // This mapping contains the price oracle per reward.

  // A price oracle is enforced for integrators @alb what is an integrator* to be able to show incentives at
  // the current Aave UI without the need to setup an external price registry

  // At the moment of reward configuration, the Incentives Controller performs
  // a check to see if the provided reward oracle contains `latestAnswer`.
  // @alb what is this latestAnswer used for?
  mapping(address => IEACAggregatorProxy) internal _rewardOracle;

  // @alb asserts whether claimer is the address authorized by user
  modifier onlyAuthorizedClaimers(address claimer, address user) {
    require(_authorizedClaimers[user] == claimer, 'CLAIMER_UNAUTHORIZED');
    _;
  }

  // @alb the contract inherits from `RewardsDistributor`
  // @alb emissionManager is the admin of the contract, and it is set in `RewardsDistributor` upon construction. It can be modified by emissionManager.
  // @alb `RewardsDistributor` provides the function modifier `onlyEmissionManager`
  constructor(address emissionManager) RewardsDistributor(emissionManager) {}

  /**
   * @dev Initialize for RewardsController
   * @param emissionManager address of the EmissionManager
   **/
  function initialize(address emissionManager) external initializer {
    _setEmissionManager(emissionManager);
  }

  /**
   * ----------------------------------------------------------------
   * // @alb Getter methods
   * ----------------------------------------------------------------
   */

  /// @inheritdoc IRewardsController
  function getClaimer(address user) external view override returns (address) {
    return _authorizedClaimers[user];
  }

  /**
   * @dev Returns the revision of the implementation contract
   * @return uint256, current revision version
   */
  function getRevision() internal pure override returns (uint256) {
    return REVISION;
  }

  /// @inheritdoc IRewardsController
  function getRewardOracle(address reward) external view override returns (address) {
    return address(_rewardOracle[reward]);
  }

  /// @inheritdoc IRewardsController
  function getTransferStrategy(address reward) external view override returns (address) {
    return address(_transferStrategy[reward]);
  }

  /**
   * @dev Get user balances and total supply of all the assets specified by the assets parameter
   * @param assets List of assets to retrieve user balance and total supply
   * @param user Address of the user
   * @return userAssetBalances contains a list of structs with user balance and total supply of the given assets
   * // @alb for reference, the list returned by this function is made of the following structs:
   * // @alb struct UserAssetBalance {
   * // @alb   address asset;
   * // @alb   uint256 userBalance;
   * // @alb   uint256 totalSupply;
   * // @alb }
   * // @alb Note: moved this method so that all getters are together.
   */
  function _getUserAssetBalances(address[] calldata assets, address user)
    internal
    view
    override
    returns (RewardsDataTypes.UserAssetBalance[] memory userAssetBalances)
  {
    userAssetBalances = new RewardsDataTypes.UserAssetBalance[](assets.length);
    for (uint256 i = 0; i < assets.length; i++) {
      userAssetBalances[i].asset = assets[i];
      // @alb ScaledBalanceToken looks similar to an ERC20, but I am not sure about the differences, e.g. what is the "scale" it refers to?
      (userAssetBalances[i].userBalance, userAssetBalances[i].totalSupply) = IScaledBalanceToken(
        assets[i]
      ).getScaledUserBalanceAndSupply(user);
    }
    return userAssetBalances;
  }

  /**
   * ----------------------------------------------------------------
   * //@alb Setter methods
   * ----------------------------------------------------------------
   */

  // @alb For a given array of assets, this sets the transferStrategy and the rewardOracle of the asset.
  // @alb Additionally, calls the function `_configureAssets` from `RewardsDistributor`. This gives RewardsDistributor 
  // @alb information about how to distribute rewards for each one of these assets.
  // @alb For reference:
  // @alb struct RewardsConfigInput {
  // @alb   uint88 emissionPerSecond;
  // @alb   uint256 totalSupply;
  // @alb   uint32 distributionEnd;
  // @alb   address asset;
  // @alb   address reward;
  // @alb   ITransferStrategyBase transferStrategy;
  // @alb   IEACAggregatorProxy rewardOracle;
  // @alb }
  /// @inheritdoc IRewardsController
  function configureAssets(RewardsDataTypes.RewardsConfigInput[] memory config)
    external
    override
    onlyEmissionManager
  {
    for (uint256 i = 0; i < config.length; i++) {
      // Get the current Scaled Total Supply of AToken or Debt token
      config[i].totalSupply = IScaledBalanceToken(config[i].asset).scaledTotalSupply();

      // Install TransferStrategy logic at IncentivesController
      _installTransferStrategy(config[i].reward, config[i].transferStrategy);

      // Set reward oracle, enforces input oracle to have latestPrice function
      _setRewardOracle(config[i].reward, config[i].rewardOracle);
    }
    _configureAssets(config);
  }

  // @alb adds a `transferStrategy` for the token with address `reward`
  // @alb Permissioned wrap of `_installTransferStrategy`
  /// @inheritdoc IRewardsController
  function setTransferStrategy(address reward, ITransferStrategyBase transferStrategy)
    external
    onlyEmissionManager
  {
    _installTransferStrategy(reward, transferStrategy);
  }

  /**
   * @dev Internal function to call the optional install hook at the TransferStrategy
   * @param reward The address of the reward token
   * @param transferStrategy The address of the reward TransferStrategy
   * // @alb Note: moved from original spot
   */
  function _installTransferStrategy(address reward, ITransferStrategyBase transferStrategy)
    internal
  {
    require(address(transferStrategy) != address(0), 'STRATEGY_CAN_NOT_BE_ZERO');
    require(_isContract(address(transferStrategy)) == true, 'STRATEGY_MUST_BE_CONTRACT');

    _transferStrategy[reward] = transferStrategy;

    emit TransferStrategyInstalled(reward, address(transferStrategy));
  }

  // @alb Same as `installTransferStrategy`, but for the oracles of the reward tokens
  /// @inheritdoc IRewardsController
  function setRewardOracle(address reward, IEACAggregatorProxy rewardOracle)
    external
    onlyEmissionManager
  {
    _setRewardOracle(reward, rewardOracle);
  }

  /**
   * @dev Update the Price Oracle of a reward token. The Price Oracle must follow Chainlink IEACAggregatorProxy interface.
   * @notice The Price Oracle of a reward is used for displaying correct data about the incentives at the UI frontend.
   * @param reward The address of the reward token
   * @param rewardOracle The address of the price oracle
   */
  function _setRewardOracle(address reward, IEACAggregatorProxy rewardOracle) internal {
    require(rewardOracle.latestAnswer() > 0, 'ORACLE_MUST_RETURN_PRICE');
    _rewardOracle[reward] = rewardOracle;
    emit RewardOracleUpdated(reward, address(rewardOracle));
  }

  // @alb Simple setter for the map `_authorizedClaimers`
  /// @inheritdoc IRewardsController
  function setClaimer(address user, address caller) external override onlyEmissionManager {
    _authorizedClaimers[user] = caller;
    emit ClaimerSet(user, caller);
  }

  /**
   * ----------------------------------------------------------------
   * // @alb
   * External methods for claiming rewards.
   * They wrap around the methods `_claimRewards` and `_claimAllRewards`
   * The latter are called by the methods here by passing `msg.sender` as some of the arguments
   * ----------------------------------------------------------------
   */

  /// @inheritdoc IRewardsController
  function claimRewards(
    address[] calldata assets,
    uint256 amount,
    address to,
    address reward
  ) external override returns (uint256) {
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimRewards(assets, amount, msg.sender, msg.sender, to, reward);
  }

  /// @inheritdoc IRewardsController
  function claimRewardsOnBehalf(
    address[] calldata assets,
    uint256 amount,
    address user,
    address to,
    address reward
  ) external override onlyAuthorizedClaimers(msg.sender, user) returns (uint256) {
    require(user != address(0), 'INVALID_USER_ADDRESS');
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimRewards(assets, amount, msg.sender, user, to, reward);
  }

  /// @inheritdoc IRewardsController
  function claimRewardsToSelf(
    address[] calldata assets,
    uint256 amount,
    address reward
  ) external override returns (uint256) {
    return _claimRewards(assets, amount, msg.sender, msg.sender, msg.sender, reward);
  }

  // @alb The following are the same as the previous methods, but in this case `amount` is set
  // @alb the maximum possible for each asset
  /// @inheritdoc IRewardsController
  function claimAllRewards(address[] calldata assets, address to)
    external
    override
    returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
  {
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimAllRewards(assets, msg.sender, msg.sender, to);
  }

  /// @inheritdoc IRewardsController
  function claimAllRewardsOnBehalf(
    address[] calldata assets,
    address user,
    address to
  )
    external
    override
    onlyAuthorizedClaimers(msg.sender, user)
    returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
  {
    require(user != address(0), 'INVALID_USER_ADDRESS');
    require(to != address(0), 'INVALID_TO_ADDRESS');
    return _claimAllRewards(assets, msg.sender, user, to);
  }

  /// @inheritdoc IRewardsController
  function claimAllRewardsToSelf(address[] calldata assets)
    external
    override
    returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
  {
    return _claimAllRewards(assets, msg.sender, msg.sender, msg.sender);
  }

  /**
   * ----------------------------------------------------------------
   * // @alb
   * Internal methods for claiming rewards
   * ----------------------------------------------------------------
   */

  /**
   * @dev Claims one type of reward for a user on behalf, on all the assets of the pool, accumulating the pending rewards.
   * @param assets List of assets to check eligible distributions before claiming rewards
   * @param amount Amount of rewards to claim
   * @param claimer Address of the claimer who claims rewards on behalf of user
   * @param user Address to check and claim rewards
   * @param to Address that will be receiving the rewards
   * @param reward Address of the reward token
   * @return Rewards claimed
   * // @alb One reward token is fixed. Then for each asset in `assets`, checks the amount of the token `rewards` that the
   * // @alb `user` has accrued. Then it transfers min(total amount of accrued reward, `amount`) to the address `to` and
   * // @alb updates the accrued rewards balances of the user.
   * // @alb NOTE: The parameter `claimer` is almost irrelevant here (it's just used while emitting an event)
   * // @alb Checking that claimer has permissions etc. is done in the previous external functions.
   **/
  function _claimRewards(
    address[] calldata assets,
    uint256 amount,
    address claimer,
    address user,
    address to,
    address reward
  ) internal returns (uint256) {
    if (amount == 0) {
      return 0;
    }
    uint256 totalRewards;

    // @alb method from RewardsDistributor
    // @alb from `RewardsDistributor` docs: Accrues all the rewards of the assets specified in the userAssetBalances list
    // @alb *Need to inspect this further*
    // @alb recall _getUserAssetBalances returns a list of structs UserAssetBalance : (asset, userBalance, totalSupply)
    _updateDataMultiple(user, _getUserAssetBalances(assets, user));

    for (uint256 i = 0; i < assets.length; i++) {
      address asset = assets[i];
      // @alb _assets[asset].rewards[reward].usersData[user].accrued = for a fixed reward, how much of this reward has 
      // @alb the deposited asset `asset` accrued
      // @alb struct AssetData {
      // @alb   mapping(address => RewardData) rewards;
      // @alb   mapping(uint128 => address) availableRewards;
      // @alb   uint128 availableRewardsCount;
      // @alb   int8 decimals;
      // @alb }
      // @alb struct RewardData {
      // @alb   uint104 index;
      // @alb   uint88 emissionPerSecond;
      // @alb   uint32 lastUpdateTimestamp;
      // @alb   uint32 distributionEnd;
      // @alb   mapping(address => UserData) usersData;
      // @alb }
      totalRewards += _assets[asset].rewards[reward].usersData[user].accrued;

      if (totalRewards <= amount) {
        // @alb If the total amount of rewards accrued computed so far is less than `amount`, then
        // @alb all rewards accrued for the current asset are withdrawn. Hence they are updated to 0 here.
        _assets[asset].rewards[reward].usersData[user].accrued = 0;
      } else {
        // @alb Otherwise, only what is remaining to reach `amount` is withdrawn. At this point the loop
        // @alb can break since totalRewards = `amount`
        uint256 difference = totalRewards - amount;
        totalRewards -= difference;
        _assets[asset].rewards[reward].usersData[user].accrued = difference.toUint128();
        break;
      }
    }

    if (totalRewards == 0) {
      return 0;
    }

    _transferRewards(to, reward, totalRewards);
    emit RewardsClaimed(user, reward, to, claimer, totalRewards);

    return totalRewards;
  }
  
  
  /**
   * @dev Function to transfer rewards to the desired account using delegatecall and
   * @param to Account address to send the rewards
   * @param reward Address of the reward token
   * @param amount Amount of rewards to transfer
   * // @alb here we see how `transferStrategy` is used in this contract
   */
  function _transferRewards(
    address to,
    address reward,
    uint256 amount
  ) internal {
    ITransferStrategyBase transferStrategy = _transferStrategy[reward];

    bool success = transferStrategy.performTransfer(to, reward, amount);

    require(success == true, 'TRANSFER_ERROR');
  }   

  /**
   * @dev Claims one type of reward for a user on behalf, on all the assets of the pool, accumulating the pending rewards.
   * @param assets List of assets to check eligible distributions before claiming rewards
   * @param claimer Address of the claimer on behalf of user
   * @param user Address to check and claim rewards
   * @param to Address that will be receiving the rewards
   * @return
   *   rewardsList List of reward addresses
   *   claimedAmount List of claimed amounts, follows "rewardsList" items order
   **/
  function _claimAllRewards(
    address[] calldata assets,
    address claimer,
    address user,
    address to
  ) internal returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    // @alb `_rewardsList` is a variable from `RewardsDistributor`
    uint256 rewardsListLength = _rewardsList.length;

    rewardsList = new address[](rewardsListLength);
    claimedAmounts = new uint256[](rewardsListLength);

    // @alb same as in `_claimRewards`
    _updateDataMultiple(user, _getUserAssetBalances(assets, user));

    // @alb for each asset, checks each reward token in _rewardsList (inherited from `RewardsDistributor`)
    // @alb and adds it to `rewardsList` if it had not been added before, and withdraws all rewards accrued,
    // @alb setting the accrued reward balance (for the current asset) to 0.
    for (uint256 i = 0; i < assets.length; i++) {
      address asset = assets[i];
      for (uint256 j = 0; j < rewardsListLength; j++) {
        if (rewardsList[j] == address(0)) {
          rewardsList[j] = _rewardsList[j];
        }
        uint256 rewardAmount = _assets[asset].rewards[rewardsList[j]].usersData[user].accrued;
        if (rewardAmount != 0) {
          claimedAmounts[j] += rewardAmount;
          _assets[asset].rewards[rewardsList[j]].usersData[user].accrued = 0;
        }
      }
    }
    // @alb For each reward address, transfers the total accrued reward to the address `to`
    for (uint256 i = 0; i < rewardsListLength; i++) {
      _transferRewards(to, rewardsList[i], claimedAmounts[i]);
      emit RewardsClaimed(user, rewardsList[i], to, claimer, claimedAmounts[i]);
    }
    return (rewardsList, claimedAmounts);
  }


  /**
   * ----------------------------------------------------------------
   * // @alb
   * Miscellaneous
   * ----------------------------------------------------------------
   */

  // @alb not sure where this is called. `_updateData` belongs to the inherited contract `RewardsDistributor`
  // @alb `_updateData` "Iterates and accrues all the rewards for asset of the specific user"
  /// @inheritdoc IRewardsController
  function handleAction(
    address user,
    uint256 totalSupply,
    uint256 userBalance
  ) external override {
    _updateData(msg.sender, user, userBalance, totalSupply);
  }

  /**
   * @dev Returns true if `account` is a contract.
   * @param account The address of the account
   * @return bool, true if contract, false otherwise
   */
  function _isContract(address account) internal view returns (bool) {
    // This method relies on extcodesize, which returns 0 for contracts in
    // construction, since the code is only stored at the end of the
    // constructor execution.

     uint256 size;
    // solhint-disable-next-line no-inline-assembly
    assembly {
      size := extcodesize(account)
    }
    return size > 0;
  }
}
