#include <iostream>

#include "core/calculator.h"

int main() {
    core::Calculator calculator;

    const int sum = calculator.add(3, 5);
    const int product = calculator.mul(4, 7);

    std::cout << "sum(3,5) = " << sum << '\n';
    std::cout << "mul(4,7) = " << product << '\n';

    return 0;
}
