# Declare this file as a StarkNet contract.
%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.uint256 import Uint256, uint256_eq, uint256_le, uint256_add, uint256_sub
from starkware.cairo.common.math import assert_lt
from starkware.cairo.common.alloc import alloc
from starkware.starknet.common.syscalls import get_caller_address
from starkware.cairo.common.registers import get_fp_and_pc

from lib.interfaces.interfaces import ITransferStrategy, IScaledBalanceToken
from lib.utils import addition_overflow_guard
from lib.events import (
    transfer_strategy_installed,
    reward_oracle_updated,
    claimer_set,
    rewards_claimed,
)

# Probably we don't need this
# using SafeCast for uint256

@storage_var
func _revision() -> (res : felt):
end

# Addresses are felts
# Using '_address' in variable names to indicate so
@storage_var
func _authorized_claimers(user_address : felt) -> (claimer_address : felt):
end

# Originally this returns `ITransferStrategy`
# Instead we return an address so that later an interface can be used with this address
@storage_var
func _transfer_strategy_address(reward_address : felt) -> (address : felt):
end

# Similar as above
@storage_var
func _reward_oracle_address(reward_address : felt) -> (address : felt):
end

# Originally this was a modifier
func only_authorized_claimers{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    claimer_address, user_address
):
    let (authorized_claimer) = _authorized_claimers.read(user_address)
    with_attr error_message("CLAIMER_UNAUTHORIZED"):
        assert authorized_claimer = claimer_address
    end
    return ()
end

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    emission_manager_address : felt
):
    # Originally this passes `emission_manager_address` to the inherited `RewardsDistributor`.
    # Here we merge the contracts into a single one.
    # Is there a better way to handle inheritance in this context?
    _emission_manager.write(emission_manager_address)
    return ()
end

# TODO: Check how proxies are handled in StarkNet
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

# Originally defined in "RewardDataTypes.sol"
# ERC20 uint256 attributes are encoded with the Uint256 struct since felts have 251 bits
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

    # Loops need to be implemented as recursive calls
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
    # Final return of the recursion
    if asset_addresses_len == 0:
        return (user_asset_balances_len, user_asset_balances)
    end

    # Fill in the struct UserAssetBalance for the current asset
    # The current asset address is obtained with [asset_addresses]
    assert user_asset_balances.asset_address = [asset_addresses]
    # Here we call a ScaledBalanceToken contract via an interface
    let (user_balance : Uint256,
        total_supply : Uint256) = IScaledBalanceToken.get_scaled_user_balance_and_supply(
        contract_address=[asset_addresses], user_address=user_address
    )
    assert user_asset_balances.user_balance = user_balance
    assert user_asset_balances.total_supply = total_supply

    # Next iteration via recurssion
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

# Originally defined in `RewardsDataTypes.sol`
struct RewardsConfigInput:
    member emission_per_second : Uint256
    member total_supply : Uint256
    member distribution_end : felt
    member asset_address : felt
    member reward_address : felt
    # As before: we use an address instead of an interface as data type
    member transfer_strategy_address : felt
    member reward_oracle_address : felt
end

@external
func configure_assets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    config_len, config : RewardsConfigInput*
):
    # Originally this was a function modifier
    only_emission_manager()
    # Loop vua recursion
    _configure_assets_inner(config_len, config)
    # Call `_configureAssets` from `RewardsDistributor`
    _configure_assets_RewardDistributor(config_len, config)
    return ()
end

func _configure_assets_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    config_len, config : RewardsConfigInput*
):
    if config_len == 0:
        return ()
    end

    # Total supply of the asset
    let (total_supply) = IScaledBalanceToken.get_scaled_total_supply(
        contract_address=config.asset_address
    )
    # Save total_supply in the RewardsConfigInput struct
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
    # Modifier
    only_emission_manager()
    _install_transfer_strategy_address(reward_address, transfer_strategy_address)
    return ()
end

func _install_transfer_strategy_address{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(reward_address, transfer_strategy_address):
    # TODO: check if this is a good StarkNet equivalent (same todo for all similar asserts in this contract)
    with_attr error_message("STRATEGY_ADDRESS_CAN_NOT_BE_ZERO"):
        assert_lt(0, transfer_strategy_address)
    end

    # No need for this: an EOA account can only call a contract with an __execute__ function
    # require(_isContract(address(transferStrategy)) == true, 'STRATEGY_MUST_BE_CONTRACT');

    _transfer_strategy_address.write(reward_address, transfer_strategy_address)

    # Emit event
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
    with_attr error_message("INVALID_TO_ADDRESS"):
        assert_lt(0, to_address)
    end

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

# As before but now the `user_address` can be different than `caller_address`
@external
func claim_rewards_on_behalf{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_addresses_len,
    asset_addresses : felt*,
    amount : Uint256,
    user_address,
    to_address,
    reward_address,
) -> (claimed_amount : Uint256):
    # Equivalent of using the "modifier" `onlyAuthorizedClaimers`
    let (caller_address) = get_caller_address()
    only_authorized_claimers(caller_address, user_address)

    with_attr error_message("INVALID_USER_ADDRESS"):
        assert_lt(0, user_address)
    end
    with_attr error_message("INVALID_TO_ADDRESS"):
        assert_lt(0, to_address)
    end

    let (claimed_amount : Uint256) = _claim_rewards(
        asset_addresses_len=asset_addresses_len,
        asset_addresses=asset_addresses,
        amount=amount,
        claimer_address=caller_address,
        user_address=user_address,
        to_address=to_address,
        reward_address=reward_address,
    )
    return (claimed_amount)
end

# TODO: rest of external claim rewards

# --------------------------------------------------------
# Internal method: _claim_rewards
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

    let total_rewards = Uint256(0, 0)

    # Equivalent of calling _updateDataMultiple
    # Accrues all the rewards of the assets specified in the userAssetBalances list
    # UserAssetBalance : (asset, userBalance, totalSupply)
    let (user_asset_balances_len : felt,
        user_asset_balances : UserAssetBalance*) = get_user_asset_balances(
        asset_addresses_len, asset_addresses, user_address
    )
    _update_data_multiple(user_address, user_asset_balances_len, user_asset_balances)

    # Rewards are collected here
    let (total_rewards : Uint256) = _claim_rewards_inner(
        asset_addresses_len, asset_addresses, amount, user_address, reward_address, total_rewards
    )

    # If no rewards have been collected, end
    let (is_total_rewards_zero) = uint256_eq(total_rewards, Uint256(0, 0))
    # Prevents revocation
    local syscall_ptr : felt* = syscall_ptr
    if is_total_rewards_zero == 1:
        return (Uint256(0, 0))
    end

    _transfer_rewards(to_address, reward_address, total_rewards)

    # Event
    rewards_claimed.emit(user_address, reward_address, to_address, claimer_address, total_rewards)
    return (total_rewards)
end

func _claim_rewards_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_addresses_len,
    asset_addresses : felt*,
    amount : Uint256,
    user_address,
    reward_address,
    total_rewards : Uint256,
) -> (new_total_rewards : Uint256):
    # Final return of the recursion
    if asset_addresses_len == 0:
        return (total_rewards)
    end

    alloc_locals
    # Prevents revocation
    local syscall_ptr : felt* = syscall_ptr

    # Gets the current asset_address in the array `asset_addresses`
    let asset_address = [asset_addresses]

    # Equivalent of `totalRewards += _assets[asset].rewards[reward].usersData[user].accrued`
    let (reward_accrued : Uint256) = get_reward_accrued(asset_address, reward_address, user_address)
    # Note we cannot update the value of total_rewards in Cairo
    let (new_total_rewards : Uint256, carry) = uint256_add(total_rewards, reward_accrued)

    # Check for overflow
    addition_overflow_guard(carry)

    let (is_total_rewards_le_amount) = uint256_le(total_rewards, amount)
    if is_total_rewards_le_amount == 1:
        # Equivalent of `_assets[asset].rewards[reward].usersData[user].accrued = 0`
        update_reward_accrued(asset_address, reward_address, user_address, Uint256(0, 0))

        # Next iteration
        return _claim_rewards_inner(
            asset_addresses_len - 1,
            asset_addresses + 1,
            amount,
            user_address,
            reward_address,
            new_total_rewards,
        )
    else:
        let (difference : Uint256) = uint256_sub(total_rewards, amount)
        let (total_rewards : Uint256) = uint256_sub(total_rewards, difference)
        # Only remove a little bit from the rewards accrued for this reward_address
        update_reward_accrued(asset_address, reward_address, user_address, difference)

        # Acts as a `break` instruction
        return (new_total_rewards)
    end
end

# Equivalent of `_assets[asset].rewards[reward].usersData[user].accrued`
func get_reward_accrued{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_address, reward_address, user_address
) -> (amount_accrued : Uint256):
    let (user_data : UserData) = asset_reward_and_user_to_UserData.read(
        asset_address, reward_address, user_address
    )
    let amount_accrued : Uint256 = user_data.accrued
    return (amount_accrued)
end

# Equivalent of `_assets[asset].rewards[reward].usersData[user].accrued = new_amount`
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

func _transfer_rewards{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    to_address, reward_address, amount : Uint256
):
    let (transfer_strategy_address) = _transfer_strategy_address.read(reward_address)

    let (success) = ITransferStrategy.perform_transfer(
        contract_address=transfer_strategy_address,
        to_address=to_address,
        reward_address=reward_address,
        amount=amount,
    )

    # Chek success
    with_attr error_message("TRANSFER_ERROR"):
        assert success = 1
    end
    return ()
end

# --------------------------------------------------------
# Internal method: _claim_all_rewards
# --------------------------------------------------------

func _claim_all_rewards{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_addresses_len : felt, asset_addresses : felt*, claimer_address, user_address, to_address
) -> (claimed_amounts_len, claimed_amounts : Uint256*):
    alloc_locals
    # _rewardsList is the global list of reward addresses
    # In Cairo we have to store its length separately
    let (reward_addresses_list_len) = _reward_addresses_list_len.read()
    let claimed_amounts_len = reward_addresses_list_len

    # TODO: I don't understand why in the solidity code they care about the list `rewardsList`
    # It looks like they are copying the state variable `_rewardsList` to `rewardsList`, so why not just return `_rewardsList`?
    # I will be ignoring the code concerning `rewardsList` for now.

    # Array to be returned: Claimed amount for each reward address
    let (claimed_amounts : Uint256*) = alloc()

    # Same as in _claim_rewards: accrues rewards
    let (user_asset_balances_len : felt,
        user_asset_balances : UserAssetBalance*) = get_user_asset_balances(
        asset_addresses_len, asset_addresses, user_address
    )
    _update_data_multiple(user_address, user_asset_balances_len, user_asset_balances)

    # Do the claiming of rewards
    let (claimed_amounts_len, claimed_amounts : Uint256*) = _claim_all_rewards_inner(
        asset_addresses_len,
        asset_addresses,
        reward_addresses_list_len,
        claimed_amounts_len,
        claimed_amounts,
        user_address,
    )

    # Transfer the rewards
    _claim_all_rewards_recursive_transfer(
        reward_addresses_list_len,
        claimed_amounts_len,
        claimed_amounts,
        user_address,
        to_address,
        claimer_address,
    )

    return (claimed_amounts_len, claimed_amounts)
end

func _claim_all_rewards_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_addresses_len : felt,
    asset_addresses : felt*,
    inner_reward_addresses_list_len,
    claimed_amounts_len,
    claimed_amounts : Uint256*,
    user_address,
) -> (claimed_amounts_len, claimed_amounts : Uint256*):
    if asset_addresses_len == 0:
        return (claimed_amounts_len, claimed_amounts)
    end

    let (reward_addresses_list_len) = _reward_addresses_list_len.read()
    # We want to read the reward addresses starting from index 0 to reward_addresses_list_len-1, not the other way around
    let (current_reward_address) = _reward_addresses_list.read(
        reward_addresses_list_len - inner_reward_addresses_list_len
    )

    # NOTE: The order of the two loops in the solidity version is
    # reversed here:
    # since claimed_amounts is what we want to return, due to
    # immutability of memory, it is better to:
    # For each reward, loop through all the assets and collect the rewards,
    # then update  "claimed_amounts[current index]" in a single step with the sum of all these rewards.
    # In the solidity contract this is done in reverse: first it iterates over the assets, and then over rewards
    let (claimed_amount_of_current_reward : Uint256) = _claim_current_reward_for_all_assets(
        asset_addresses_len, asset_addresses, user_address, current_reward_address
    )
    
    # "Store" the claimed amount in the array `claimed_amounts`
    assert [claimed_amounts] = claimed_amount_of_current_reward
    return _claim_all_rewards_inner(
        asset_addresses_len,
        asset_addresses,
        inner_reward_addresses_list_len - 1,
        claimed_amounts_len + 1,
        claimed_amounts + Uint256.SIZE,
        user_address,
    )
end

# For a fixed reward_address and user, it loops over a list of asset addresses and claims all accrued rewards
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
    local syscall_ptr : felt* = syscall_ptr

    if asset_addresses_len == 0:
        return (claimed_amount)
    end

    let asset_address = [asset_addresses]

    let (reward_for_current_asset : Uint256) = get_reward_accrued(
        asset_address, reward_address, user_address
    )

    # TODO: here we can avoid these calls if `reward_for_current_asset` is 0.
    # I had some problems with revocations so for now I am making the update in all cases.
    update_reward_accrued(asset_address, reward_address, user_address, new_amount=Uint256(0, 0))
    let (new_claimed_amount : Uint256, carry) = uint256_add(
        claimed_amount, reward_for_current_asset
    )

    # Takes care of possible overflow
    addition_overflow_guard(carry)

    return _claim_current_reward_for_all_assets_inner(
        asset_addresses_len - 1,
        asset_addresses + 1,
        user_address,
        reward_address,
        new_claimed_amount,
    )
end

func _claim_all_rewards_recursive_transfer{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(
    inner_reward_addresses_list_len,
    claimed_amounts_len,
    claimed_amounts : Uint256*,
    user_address,
    to_address,
    claimer_address,
):
    if inner_reward_addresses_list_len == 0:
        return ()
    end

    # Gets the current reward address and claimed amount
    let amount : Uint256 = [claimed_amounts]

    # As before, we want to read the reward addresses starting from index 0 to reward_addresses_list_len-1, not the other way around
    let (reward_addresses_list_len) = _reward_addresses_list_len.read()
    let (current_reward_address) = _reward_addresses_list.read(
        reward_addresses_list_len - inner_reward_addresses_list_len
    )
    let (reward_address) = _reward_addresses_list.read(current_reward_address)

    _transfer_rewards(to_address, reward_address, amount)

    rewards_claimed.emit(user_address, reward_address, to_address, claimer_address, amount)

    _claim_all_rewards_recursive_transfer(
        inner_reward_addresses_list_len - 1,
        claimed_amounts_len - 1,
        claimed_amounts + Uint256.SIZE,
        user_address,
        to_address,
        claimer_address,
    )
    return ()
end

# --------------------------------------------------------
# --------------------------------------------------------
#
# Rewards Distributor
#
# Minimal implementation of some elements from `RewardsDistributor.sol`
#
# --------------------------------------------------------
# --------------------------------------------------------

# --------------------------------------------------------
# AssetData, RewardData, UserData structs
# --------------------------------------------------------

# Big difference from the solidity code: struct AssetData contains two mappings which AFAIK cannot be reproduced in Cairo.
# Instead, we use storage variables `asset_and_reward_to_reward_data` and `available_rewards`
struct AssetData:
    # NOTE: This is a uint128 in solidity, so we could use a felt here,
    # but it could run into incompatibilities later if it has to be operated with a Uint256
    member available_rewards_count : Uint256
    member decimals : felt
end

# "Tied" to an asset_address and a reward_address
struct RewardData:
    member index : felt
    member emissions_per_second : felt
    member last_update_timestamp : felt
    member distribution_end : felt
end

# Replaces `mapping(address => RewardData) rewards;` from AssetData
@storage_var
func asset_and_reward_to_RewardData(asset_address, reward_address) -> (data : RewardData):
end

# Replaces `mapping(uint128 => address) availableRewards;` from AssetData
# The uint128 is an index
@storage_var
func available_rewards(asset_address, reward_address_index) -> (reward_address):
end

# "Tied" to an asset_address, a reward_address, and a user_address
# Indicates amount of reward accrued by the user for the asset
struct UserData:
    # matches the index in the corresponding `RewardData`
    # i.e. `asset_and_reward_to_reward_data(asset_address, reward_address).index`
    member index : felt
    # uint128 in solidity, but we will need to operate it with Uint256's
    member accrued : Uint256
end

# Replaces `mapping(address => UserData) usersData;` in RewardData
@storage_var
func asset_reward_and_user_to_UserData(asset_address, reward_address, user_address) -> (
    res : UserData
):
end

# --------------------------------------------

@storage_var
func _emission_manager() -> (address : felt):
end

# Used in _claim_all_rewards
# "Simulation" of a list in StarkNet. Replaces:
# address[] internal _rewardsList;
@storage_var
func _reward_addresses_list(index) -> (reward_address):
end
# This allows to retrieve the length of the list
@storage_var
func _reward_addresses_list_len() -> (len):
end

# Asserts that the caller is the emission_manager (= the admin)
func only_emission_manager{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    # Equivalent of `msg.sender`
    let (caller_address) = get_caller_address()
    let (emission_manager_address) = _emission_manager.read()
    with_attr error_message("NOT_EMISSION_MANAGER"):
        assert caller_address = emission_manager_address
    end
    return ()
end

# Two function from RewardsDistributor.sol, added here as dummys
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
