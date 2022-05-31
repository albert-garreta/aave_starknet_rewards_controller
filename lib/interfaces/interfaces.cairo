%lang starknet

from starkware.cairo.common.uint256 import Uint256


@contract_interface
namespace ITransferStrategy:
    func perform_transfer(to_address, reward_address, amount:Uint256) -> (bool: felt):
    end
end

@contract_interface
namespace IScaledBalanceToken:
    func get_scaled_total_supply() -> (supply: Uint256):
    end
    
    func get_scaled_user_balance_and_supply(user_address) -> (scaled_balance: Uint256, supply: Uint256):
    end
end
