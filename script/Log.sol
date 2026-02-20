// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

abstract contract Log is Test {
    function recordDeployment(address deployedAddress, string memory name) public {
        string memory md = string.concat("## ", name, " Deployment on chainId ", vm.toString(block.chainid), "\n\n");
        string memory table = string.concat("| Contract Name | Address |\n| --- | --- |\n");
        table = string.concat(table, string.concat("| ", name, " | ", vm.toString(deployedAddress), " |\n"));
        md = string.concat(md, table);
        vm.writeFile(string.concat("deployments/", vm.toString(block.chainid), "/", name, ".md"), md);
    }
}
