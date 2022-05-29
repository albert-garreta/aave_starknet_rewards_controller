%lang starknet

from starkware.cairo.common.uint256 import Uint256

@contract_interface
namespace IRewardsDistributor:
    func _set_emission_manager(emission_manager_address):
    end
end

@contract_interface
namespace ITransferStrategy:
    func perform_transfer(to_address, reward_address, amount:Uint256) -> (bool: felt):
    end
end

@contract_interface
namespace IScaledBalanceToken:
    func get_scaled_total_supply() -> (res):
    end
end
