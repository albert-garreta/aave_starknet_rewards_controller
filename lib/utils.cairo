from starkware.cairo.common.math import assert_lt

# NOTE: Overflow in Uint256 should be handled, for example, with OpenZeppelin's SafeUint256 
# https://github.com/OpenZeppelin/cairo-contracts/blob/main/src/openzeppelin/security/safemath.cairo

# `carry` is the carry from a Uint256 addition.
# If carry = 1, there has been overflow. 
# If carry = 0, then all is fine
func addition_overflow_guard{range_check_ptr}(carry : felt):
    with_attr error_message("INTEGER_OVERFLOW"):
        assert_lt(carry, 1)
    end
    return ()
end
