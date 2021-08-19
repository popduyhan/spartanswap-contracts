// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.3;
import "./iBEP20.sol";
import "./iBASE.sol";
import "./iDAO.sol";

contract Reserve {
    address public immutable BASE;
    address public DEPLOYER;
    bool public emissions;
    bool public globalFreeze;

    // Restrict access
    modifier onlyGrantor() {
        require(msg.sender == _DAO().DAO() || msg.sender == _DAO().ROUTER() || msg.sender == _DAO().SYNTHVAULT() || msg.sender == DEPLOYER || msg.sender == _DAO().LEND(), "!DAO"); 
        _; 
    }

    constructor (address _base) {
        require(_base != address(0), '!ZERO');
        BASE = _base;
        DEPLOYER = msg.sender;
    }

    function _DAO() internal view returns(iDAO) {
        return iBASE(BASE).DAO();
    }

    // Send SPARTA to an incentive address (Vault harvest, dividends etc)
    function grantFunds(uint amount, address to) external onlyGrantor {
        uint reserve = iBEP20(BASE).balanceOf(address(this)); // Get RESERVE's SPARTA balance
        if(amount > 0){ // Skip if amount is not valid
            if(emissions){ // Skip if emissions are off
                if(amount > reserve){
                    iBEP20(BASE).transfer(to, reserve); // Send remainder
                } else {
                    iBEP20(BASE).transfer(to, amount); // Send requested amount
                }
            }
        }
    }

    function flipEmissions() external onlyGrantor {
        emissions = !emissions; // Flip emissions on/off
    }

    function setGlobalFreeze(bool freeze) external onlyGrantor {
        globalFreeze = freeze;
        emissions = !freeze;
    }
   
    // Can purge deployer once DAO is stable and final
    function purgeDeployer() external onlyGrantor {
        DEPLOYER = address(0);
    }
}