# Declare this file as a StarkNet contract.
%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.uint256 import Uint256, uint256_eq, uint256_le, uint256_add, uint256_sub
from starkware.cairo.common.alloc import alloc
from starkware.starknet.common.syscalls import get_caller_address
from starkware.cairo.common.registers import get_fp_and_pc

from lib.interfaces.interfaces import IRewardsDistributor, ITransferStrategy, IScaledBalanceToken
from lib.events import (
    transfer_strategy_installed,
    reward_oracle_updated,
    claimer_set,
    rewards_claimed,
)
# using SafeCast for uint256

# TODO: comment
@storage_var
func _rewards_distributor_address() -> (address : felt):
end

@storage_var
func _revision() -> (res : felt):
end

# Addresses are felts
@storage_var
func _authorized_claimers(user : felt) -> (claimer : felt):
end

# Here originally the interface `ITransferStrategy` is returned. Instead return an address so that later an interface can be used with this address
@storage_var
func _transfer_strategy_address(reward_address : felt) -> (address : felt):
end

@storage_var
func _reward_oracle_address(reward_address : felt) -> (address : felt):
end

# // @alb asserts whether claimer is the address authorized by user
# modifier onlyAuthorizedClaimers(address claimer, address user) {
#   require(_authorizedClaimers[user] == claimer, # 'CLAIMER_UNAUTHORIZED');
#   _;
# }

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    emission_manager_address : felt
):
    let (rewards_dist) = _rewards_distributor_address.read()
    IRewardsDistributor._set_emission_manager(
        contract_address=rewards_dist, emission_manager_address=emission_manager_address
    )
    return ()
end

# /**
#  * @dev Initialize for RewardsController
#  * @param emissionManager address of the EmissionManager
#  **/
# function initialize(address emissionManager) external initializer {
#   _setEmissionManager(emissionManager);
# }

# ---------------------------------------------------------
# Getters
# ---------------------------------------------------------

@view
func get_claimer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address
) -> (claimer_address):
    let (claimer_address) = _authorized_claimers.read(user_address)
    return (claimer_address)
end

@view
func get_revision{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    revision
):
    let (revision) = _revision.read()
    return (revision)
end

@view
func get_reward_oracle{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    reward_address
) -> (oracle_address):
    let (oracle_address) = _reward_oracle_address.read(reward_address)
    return (oracle_address)
end

@view
func get_transfer_strategy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    reward_address
) -> (transfer_strategy_address):
    let (transfer_strategy_address) = _transfer_strategy_address.read(reward_address)
    return (transfer_strategy_address)
end

struct UserAssetBalance:
    member asset_address : felt
    member user_balance : Uint256
    member total_supply : Uint256
end

@view
func get_user_asset_balances{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_addresses_len : felt, asset_addresses : felt*, user_address
) -> (user_asset_balances_len, user_asset_balances : UserAssetBalance*):
    # Replaces userAssetBalances = new RewardsDataTypes.UserAssetBalance[](assets.length);
    let (user_asset_balances : UserAssetBalance*) = alloc()

    let (user_asset_balances_len,
        user_asset_balances : UserAssetBalance*) = _get_user_asset_balances_inner(
        asset_addresses_len,
        asset_addresses,
        user_address,
        user_asset_balances_len=0,
        user_asset_balances=user_asset_balances,
    )
    return (user_asset_balances_len, user_asset_balances)
end

func _get_user_asset_balances_inner{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(
    asset_addresses_len,
    asset_addresses : felt*,
    user_address,
    user_asset_balances_len,
    user_asset_balances : UserAssetBalance*,
) -> (user_asset_balances_len, user_asset_balances : UserAssetBalance*):
    if asset_addresses_len == 0:
        return (user_asset_balances_len, user_asset_balances)
    end

    assert user_asset_balances.asset_address = [asset_addresses]
    let (user_balance : Uint256,
        total_supply : Uint256) = IScaledBalanceToken.get_scaled_user_balance_and_supply(
        contract_address=[asset_addresses], user_address=user_address
    )
    assert user_asset_balances.user_balance = user_balance
    assert user_asset_balances.total_supply = total_supply

    return _get_user_asset_balances_inner(
        asset_addresses_len - 1,
        asset_addresses + 1,
        user_address,
        user_asset_balances_len + 1,
        user_asset_balances + UserAssetBalance.SIZE,
    )
end

# ---------------------------------------------------------
# Setters
# ---------------------------------------------------------

struct RewardsConfigInput:
    member emission_per_second : Uint256
    member total_supply : Uint256
    member distribution_end : felt
    member asset_address : felt
    member reward_address : felt
    # differences here
    member transfer_strategy_address : felt
    member reward_oracle_address : felt
end

@external
func configure_assets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    config_len, config : RewardsConfigInput*
):
    # new
    only_emission_manager()
    _configure_assets_inner(config_len, config)
    _configure_assets_RewardDistributor(config_len, config)
    return ()
end

func _configure_assets_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    config_len, config : RewardsConfigInput*
):
    if config_len == 0:
        return ()
    end

    let (total_supply) = IScaledBalanceToken.get_scaled_total_supply(
        contract_address=config.asset_address
    )
    assert config.total_supply = total_supply

    _install_transfer_strategy_address(config.reward_address, config.transfer_strategy_address)

    _set_reward_oracle_address(config.reward_address, config.reward_oracle_address)

    # Recurrence call instead of looping
    return _configure_assets_inner(
        config_len=config_len - 1, config=config + RewardsConfigInput.SIZE
    )
end

@external
func set_transfer_strategy_address{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(reward_address, transfer_strategy_address):
    only_emission_manager()
    _install_transfer_strategy_address(reward_address, transfer_strategy_address)
    return ()
end

func _install_transfer_strategy_address{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(reward_address, transfer_strategy_address):
    # TODO:
    # require(address(transferStrategy) != address(0), 'STRATEGY_CAN_NOT_BE_ZERO');

    # No need for this: an EOA account can only call a contract with an __execute__ function
    # require(_isContract(address(transferStrategy)) == true, 'STRATEGY_MUST_BE_CONTRACT');

    _transfer_strategy_address.write(reward_address, transfer_strategy_address)

    # NOTE: Emit event
    transfer_strategy_installed.emit(reward_address, transfer_strategy_address)
    return ()
end

@external
func set_reward_oracle_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    reward_address, reward_oracle_address
):
    only_emission_manager()
    _set_reward_oracle_address(reward_address, reward_oracle_address)
    return ()
end

func _set_reward_oracle_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    reward_address, reward_oracle_address
):
    # TODO:
    #     require(rewardOracle.latestAnswer() > 0, 'ORACLE_MUST_RETURN_PRICE');

    _reward_oracle_address.write(reward_address, reward_oracle_address)

    reward_oracle_updated.emit(reward_address, reward_oracle_address)
    return ()
end

@external
func set_claimer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, claimer_address
):
    only_emission_manager()
    _authorized_claimers.write(user_address, claimer_address)

    claimer_set.emit(user_address, claimer_address)
    return ()
end

# --------------------------------------------------------
# External methods for claiming rewards
# --------------------------------------------------------

@external
func claim_rewards{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_addresses_len, asset_addresses : felt*, amount : Uint256, to_address, reward_address
) -> (claimed_amount : Uint256):
    # TODO: this
    # require(to != address(0), 'INVALID_TO_ADDRESS');

    # Equivalent of msg.sender
    let (caller_address) = get_caller_address()
    let (claimed_amount : Uint256) = _claim_rewards(
        asset_addresses_len=asset_addresses_len,
        asset_addresses=asset_addresses,
        amount=amount,
        claimer_address=caller_address,
        user_address=caller_address,
        to_address=to_address,
        reward_address=reward_address,
    )
    return (claimed_amount)
end

# TODO: rest of external claim rewards

# --------------------------------------------------------
# Internal methods for claiming rewards
# --------------------------------------------------------

func _claim_rewards{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_addresses_len : felt,
    asset_addresses : felt*,
    amount : Uint256,
    claimer_address,
    user_address,
    to_address,
    reward_address,
) -> (claimed_amount : Uint256):
    alloc_locals

    let (is_amount_zero) = uint256_eq(amount, Uint256(0, 0))
    if is_amount_zero == 1:
        return (Uint256(0, 0))
    end

    let (user_asset_balances_len : felt,
        user_asset_balances : UserAssetBalance*) = get_user_asset_balances(
        asset_addresses_len, asset_addresses, user_address
    )
    _update_data_multiple(user_address, user_asset_balances_len, user_asset_balances)

    # We use Uint256
    let total_rewards = Uint256(0, 0)

    let (total_rewards : Uint256) = _claim_rewards_inner(
        asset_addresses_len, asset_addresses, amount, user_address, reward_address, total_rewards
    )

    let (is_total_rewards_zero) = uint256_eq(total_rewards, Uint256(0, 0))

    # Prevents revocation
    local syscall_ptr : felt* = syscall_ptr
    if is_total_rewards_zero == 1:
        return (Uint256(0, 0))
    end

    _transer_rewards(to_address, reward_address, total_rewards)

    rewards_claimed.emit(user_address, reward_address, to_address, total_rewards)
    return (total_rewards)
end

func _claim_rewards_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_addresses_len,
    asset_addresses : felt*,
    amount : Uint256,
    user_address,
    reward_address,
    total_rewards : Uint256,
) -> (total_rewards : Uint256):
    if asset_addresses_len == 0:
        return (total_rewards)
    end

    alloc_locals
    # Prevents revocation
    local syscall_ptr : felt* = syscall_ptr

    let asset_address = [asset_addresses]

    # Replaces `_assets[asset].rewards[reward].usersData[user].accrued`
    let (reward_accrued : Uint256) = get_reward_accrued(asset_address, reward_address, user_address)

    # TODO: what to do with overflows here
    let (total_rewards : Uint256, carry) = uint256_add(total_rewards, reward_accrued)

    let (is_total_rewards_le_amount) = uint256_le(total_rewards, amount)
    if is_total_rewards_le_amount == 1:
        update_reward_accrued(asset_address, reward_address, user_address, Uint256(0, 0))
        return _claim_rewards_inner(
            asset_addresses_len - 1,
            asset_addresses + 1,
            amount,
            user_address,
            reward_address,
            total_rewards,
        )
    else:
        let (difference : Uint256) = uint256_sub(total_rewards, amount)
        let (total_rewards : Uint256) = uint256_sub(total_rewards, difference)
        update_reward_accrued(asset_address, reward_address, user_address, difference)

        return (total_rewards)
    end
end

# TODO: document
# New function
func get_reward_accrued{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_address, reward_address, user_address
) -> (amount_accrued : Uint256):
    let (user_data : UserData) = asset_reward_and_user_to_UserData.read(
        asset_address, reward_address, user_address
    )
    let amount_accrued : Uint256 = user_data.accrued
    return (amount_accrued)
end

# TODO: document
# New function
func update_reward_accrued{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_address, reward_address, user_address, new_amount : Uint256
):
    let (user_data : UserData) = asset_reward_and_user_to_UserData.read(
        asset_address, reward_address, user_address
    )
    let new_user_data = UserData(index=user_data.index, accrued=new_amount)
    asset_reward_and_user_to_UserData.write(
        asset_address, reward_address, user_address, new_user_data
    )
    return ()
end

# TODO: this
# _claimALLRewards

func _claim_all_rewards{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_addresses_len : felt, asset_addresses : felt*, claimer_address, user_address, to_address
) -> (
    reward_addresses_list_len,
    reward_addresses_list : felt*,
    claimed_amounts_len,
    claimed_amounts : Uint256*,
):
    alloc_locals

    let (reward_addresses_list_len) = _reward_addresses_list_len.read()
    let claimed_amounts_len = reward_addresses_list_len

    let (reward_addresses_list : felt*) = alloc()
    let (claimed_amounts : Uint256*) = alloc()

    let (user_asset_balances_len : felt,
        user_asset_balances : UserAssetBalance*) = get_user_asset_balances(
        asset_addresses_len, asset_addresses, user_address
    )
    _update_data_multiple(user_address, user_asset_balances_len, user_asset_balances)

    let (reward_addresses_list_len, reward_addresses_list : felt*, claimed_amounts_len,
        claimed_amounts : Uint256*) = _claim_all_rewards_inner(
        asset_addresses_len,
        asset_addresses,
        reward_addresses_list_len,
        reward_addresses_list,
        claimed_amounts_len,
        claimed_amounts,
        user_address,
    )

    return (reward_addresses_list_len, reward_addresses_list, claimed_amounts_len, claimed_amounts)
end

func _claim_all_rewards_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_addresses_len : felt,
    asset_addresses : felt*,
    reward_addresses_list_len,
    reward_addresses_list : felt*,
    claimed_amounts_len,
    claimed_amounts : Uint256*,
    user_address,
) -> (
    reward_addresses_list_len,
    reward_addresses_list : felt*,
    claimed_amounts_len,
    claimed_amounts : Uint256*,
):
    if asset_addresses_len == 0:
        return (
            reward_addresses_list_len, reward_addresses_list, claimed_amounts_len, claimed_amounts
        )
    end

    let current_reward_address = [reward_addresses_list]

    let (claimed_amount_of_current_reward : Uint256) = _claim_current_reward_for_all_assets(
        asset_addresses_len, asset_addresses, user_address, current_reward_address
    )

    assert [claimed_amounts] = claimed_amount_of_current_reward
    return _claim_all_rewards_inner(
        asset_addresses_len,
        asset_addresses,
        reward_addresses_list_len - 1,
        reward_addresses_list + 1,
        claimed_amounts_len + 1,
        claimed_amounts + Uint256.SIZE,
        user_address,
    )
end

func _claim_current_reward_for_all_assets{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(asset_addresses_len : felt, asset_addresses : felt*, user_address, reward_address) -> (
    claimed_amount_of_current_reward : Uint256
):
    let claimed_amount = Uint256(0, 0)
    let (claimed_amount : Uint256) = _claim_current_reward_for_all_assets_inner(
        asset_addresses_len, asset_addresses, user_address, reward_address, claimed_amount
    )

    return (claimed_amount)
end

func _claim_current_reward_for_all_assets_inner{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(
    asset_addresses_len : felt,
    asset_addresses : felt*,
    user_address,
    reward_address,
    claimed_amount : Uint256,
) -> (new_claimed_amount : Uint256):
    
    alloc_locals
    local syscall_ptr: felt* = syscall_ptr
    
    if asset_addresses_len == 0:
        return (claimed_amount)
    end
    
    let asset_address = [asset_addresses]

    let (reward_for_current_asset : Uint256) = get_reward_accrued(
        asset_address, reward_address, user_address
    )
    
    # TODO: here we could avoid these if `reward_for_current_asset` is 0. I had some problems with revocations so for now I am making the update in all cases.
    update_reward_accrued(asset_address, reward_address, user_address, new_amount=Uint256(0, 0))
    # TODO: manage possible overflow
    let (new_claimed_amount : Uint256, carry) = uint256_add(claimed_amount, reward_for_current_asset)
    
    return _claim_current_reward_for_all_assets_inner(
        asset_addresses_len - 1,
        asset_addresses + 1,
        user_address,
        reward_address,
        new_claimed_amount,
    )
end

func _transer_rewards{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    to_address, reward_address, amount : Uint256
):
    let (transfer_strategy_address) = _transfer_strategy_address.read(reward_address)

    let (success) = ITransferStrategy.perform_transfer(
        contract_address=transfer_strategy_address,
        to_address=to_address,
        reward_address=reward_address,
        amount=amount,
    )

    # Chek success and print error message if needed
    with_attr error_message("TRANSFER_ERROR"):
        assert success = 1
    end
    return ()
end

# --------------------------------------------------------
# Rewards Distributor
# --------------------------------------------------------

# --------------------------------------------------------
# AssetData, RewardData, UserData structs
# --------------------------------------------------------

# Big difference from the solidity code: AssetData contains two mappings which AFAIK cannot be reproduced in Cairo.
# Instead, we use storage variables `asset_and_reward_to_reward_data` and `vailable_rewards`
struct AssetData:
    # NOTE: This is a uint128 in solidity, so we could use a felt here, but it could run into incompatibilities later if it has to be operated with a Uint256
    member available_rewards_count : Uint256
    member decimals : felt
end

struct RewardData:
    member index : felt
    member emissions_per_second : felt
    member last_update_timestamp : felt
    member distribution_end : felt
end

struct UserData:
    # matches the index in `asset_and_reward_to_reward_data(asset_address, reward_address).index`
    member index : felt
    # in solidity this is actually a uint128, but we will need to operate it with Uint256's (I think)
    member accrued : Uint256
end

# For each asset and reward, returns a struct containing information about the reward for such asset
@storage_var
func asset_and_reward_to_RewardData(asset_address, reward_address) -> (data : RewardData):
end

# Simulates a mapping from asset_address into a list of reward_addresses which are available for such asset_address
@storage_var
func available_rewards(asset_address, reward_address_index) -> (reward_address):
end

@storage_var
func asset_reward_and_user_to_UserData(asset_address, reward_address, user_address) -> (
    res : UserData
):
end

# --------------------------------------------

# This would be the state variable _assets in the solidity version
@storage_var
func _assets_rewards(asset_address) -> (asset_and_asset_and_reward_to_reward_data : AssetData):
end

@storage_var
func _emission_manager() -> (address : felt):
end

# "Simulation" of a list in StarkNet. Replaces:
# address[] internal _rewardsList;
@storage_var
func _reward_addresses_list(index) -> (reward_address):
end

# This allows to retrieve the length of the list
@storage_var
func _reward_addresses_list_len() -> (len):
end

func only_emission_manager{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (caller_address) = get_caller_address()
    let (emission_manager_address) = _emission_manager.read()
    assert caller_address = emission_manager_address
    return ()
end

# TODO: name
func _configure_assets_RewardDistributor{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(config_len, config : RewardsConfigInput*):
    # dummy
    return ()
end

func _update_data_multiple{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    usser_address, user_asset_balances_len, user_asset_balances_array : UserAssetBalance*
):
    # dummy
    return ()
end
