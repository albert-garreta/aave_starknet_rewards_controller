%lang starknet

from starkware.cairo.common.uint256 import Uint256


@event
func transfer_strategy_installed(reward_address, transfer_strategy_address):
end

@event
func reward_oracle_updated(reward_address, reward_oracle_address):
end

@event
func claimer_set(user_address, claimer_address):
end

@event
func rewards_claimed(user_address, reward_address, to_address, claimer_address, total_rewards : Uint256):
end

