%lang starknet

from starkware.starknet.common.syscalls import get_caller_address
from starkware.cairo.common.cairo_builtins import HashBuiltin

@storage_var
func _emission_manager() -> (address : felt):
end

func only_emission_manager{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (caller_address) = get_caller_address()
    let (emission_manager_address) = _emission_manager.read()
    assert caller_address = emission_manager_address
end
