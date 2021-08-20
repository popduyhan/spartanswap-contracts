// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.3;
import "./Pool.sol";
import "./iRESERVE.sol"; 
import "./iPOOLFACTORY.sol";  
import "./iWBNB.sol";
import "hardhat/console.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Router is ReentrancyGuard {
    address public immutable BASE;
    address public immutable WBNB;
    address public DEPLOYER;
    uint256 public diviClaim;
    uint256 public globalCAP;
    uint private feeAllocation;         // Amount of dividend events per era
    uint public lastMonth;          // Timestamp of the start of current metric period (For UI)
    uint256 public curatedPoolsCount;

    mapping(address=> uint) public mapAddress_30DayDividends;
    mapping(address=> uint) public mapAddress_Past30DayPoolDividends;

    // Restrict access
    modifier onlyDAO() {
        require(msg.sender == _DAO().DAO() || msg.sender == DEPLOYER);
        _;
    }

    constructor (address _base, address _wbnb) {
        require(_base != address(0), '!ZERO');
        require(_wbnb != address(0), '!ZERO');
        BASE = _base;
        WBNB = _wbnb;
        feeAllocation = 100;
        lastMonth = 0;
        globalCAP = 2000;
        diviClaim = 100;
        DEPLOYER = msg.sender;
    }

    receive() external payable {} // Used to receive BNB from WBNB contract

    function _DAO() internal view returns(iDAO) {
        return iBASE(BASE).DAO();
    }

    // User adds liquidity
    function addLiquidity(uint inputToken, address token) external payable{
        addLiquidityForMember(inputToken, token, msg.sender);
    }

    // Contract adds liquidity for user
    function addLiquidityForMember(uint inputToken, address token, address member) public payable {
        address pool = iPOOLFACTORY(_DAO().POOLFACTORY()).getPool(token);  // Get pool address
        require(pool != address(0), "!POOL"); // Must be a valid pool
        uint256 baseAmount = iUTILS(_DAO().UTILS()).calcSwapValueInBase(token, inputToken); 
        _handleTransferIn(BASE, baseAmount, pool); // Transfer SPARTA to pool
        _handleTransferIn(token, inputToken, pool); // Transfer TOKEN to pool
        Pool(pool).addForMember(member); // Add liquidity to pool for user
        _safetyTrigger(pool);
    }

    function addLiquidityAsym(uint input, bool fromBase, address token) external payable {
        addLiquidityAsymForMember(input, fromBase, token, msg.sender);
    }

    function addLiquidityAsymForMember(uint _input, bool _fromBase, address _token, address _member) public payable {
        address _pool = iPOOLFACTORY(_DAO().POOLFACTORY()).getPool(_token); // Get pool address
        require(_pool != address(0), "!POOL"); // Must be a valid pool
        _handleTransferIn(_token, _input, address(this)); // Transfer TOKEN / BNB into pool
        if(_fromBase){
            swapTo((_input / 2), BASE, _token, address(this), 0);
        } else {
            swapTo((_input / 2), _token, BASE, address(this), 0);
        }
        if(_token == address(0)){
             _handleTransferOut(WBNB, iBEP20(WBNB).balanceOf(address(this)), _pool);
        }else{
             _handleTransferOut(_token, iBEP20(_token).balanceOf(address(this)), _pool);
        }
        Pool(_pool).addForMember(_member); // Add liquidity and send LPs to user
        _safetyTrigger(_pool);
    }


    // Trade LP tokens for another type of LP tokens
    function zapLiquidity(uint unitsInput, address fromPool, address toPool) external {
        require(fromPool != toPool && unitsInput > 0, '!VALID'); // Pools must be different and input must be valid
        iPOOLFACTORY _poolFactory = iPOOLFACTORY(_DAO().POOLFACTORY());
        require(_poolFactory.isPool(fromPool) == true); // FromPool must be a valid pool
        require(_poolFactory.isPool(toPool) == true); // ToPool must be a valid pool
        address _fromToken = Pool(fromPool).TOKEN(); // Get token underlying the fromPool
        address _member = msg.sender; // Get user's address
        iBEP20(fromPool).transferFrom(_member, fromPool, unitsInput); // Transfer LPs from user to the pool
        Pool(fromPool).removeForMember(address(this)); // Remove liquidity to ROUTER
        iBEP20(_fromToken).transfer(fromPool, iBEP20(_fromToken).balanceOf(address(this))); // Transfer TOKENs from ROUTER to fromPool
        Pool(fromPool).swapTo(BASE, toPool); // Swap the received TOKENs for SPARTA then transfer to the toPool
        iBEP20(BASE).transfer(toPool, iBEP20(BASE).balanceOf(address(this))); // Transfer SPARTA from ROUTER to toPool
        Pool(toPool).addForMember(_member); // Add liquidity and send the LPs to user
        _safetyTrigger(fromPool);
        _safetyTrigger(toPool);
    }

    // User removes liquidity - redeems a percentage of their balance
    function removeLiquidity(uint basisPoints, address token) external{
        require(basisPoints > 0, '!VALID'); // Must be valid basis points, calcPart() handles the upper-check
        uint _units = iUTILS(_DAO().UTILS()).calcPart(basisPoints, iBEP20(iPOOLFACTORY(_DAO().POOLFACTORY()).getPool(token)).balanceOf(msg.sender));
        removeLiquidityExact(_units, token);
    }

    // User removes liquidity - redeems exact qty of LP tokens
    function removeLiquidityExact(uint units, address token) public {
        require(units > 0, '!VALID'); // Must be a valid amount
        address _pool = iPOOLFACTORY(_DAO().POOLFACTORY()).getPool(token); // Get the pool address
        require(iRESERVE(_DAO().RESERVE()).globalFreeze() != true, '');
        require(_pool != address(0), "!POOL"); // Must be a valid pool
        address _member = msg.sender; // The the user's address
        iBEP20(_pool).transferFrom(_member, _pool, units); // Transfer LPs to the pool
        if(token != address(0)){
            Pool(_pool).removeForMember(_member); // Remove liquidity and send assets directly to user
        } else {
            Pool(_pool).removeForMember(address(this)); // If BNB; remove liquidity and send to ROUTER instead
            uint outputBase = iBEP20(BASE).balanceOf(address(this)); // Get the received SPARTA amount
            uint outputToken = iBEP20(WBNB).balanceOf(address(this)); // Get the received WBNB amount
            _handleTransferOut(token, outputToken, _member); // Unwrap to BNB & tsf it to user
            _handleTransferOut(BASE, outputBase, _member); // Transfer SPARTA to user
        }
        _safetyTrigger(_pool);
    }

    function removeLiquidityAsym(uint units, bool toBase, address token) external {
        require(units > 0, '!VALID'); // Must be a valid amount
        address _pool = iPOOLFACTORY(_DAO().POOLFACTORY()).getPool(token); // Get pool address
        require(iRESERVE(_DAO().RESERVE()).globalFreeze() != true, '');
        require(_pool != address(0), "!POOL"); // Must be a valid pool
        require(iPOOLFACTORY(_DAO().POOLFACTORY()).isPool(_pool) == true); // Pool must be valid
        address _member = msg.sender; // Get user's address
        iBEP20(_pool).transferFrom(_member, _pool, units); // Transfer LPs to pool
        Pool(_pool).removeForMember(address(this)); // Remove liquidity & tsf to ROUTER
        address _token = token; // Get token address
        if(token == address(0)){_token = WBNB;} // Handle BNB -> WBNB
        if(toBase){
            iBEP20(_token).transfer(_pool, iBEP20(_token).balanceOf(address(this))); // Transfer TOKEN to pool
            Pool(_pool).swapTo(BASE, address(this)); // Swap TOKEN for SPARTA & tsf to ROUTER
            iBEP20(BASE).transfer(_member, iBEP20(BASE).balanceOf(address(this))); // Transfer all SPARTA from ROUTER to user
        } else {
            iBEP20(BASE).transfer(_pool, iBEP20(BASE).balanceOf(address(this))); // Transfer SPARTA to pool
            Pool(_pool).swapTo(_token, address(this)); // Swap SPARTA for TOKEN & transfer to ROUTER
            _handleTransferOut(token, iBEP20(_token).balanceOf(address(this)), _member); // Send TOKEN to user
        } 
        _safetyTrigger(_pool);
    }

 
    //============================== Swapping Functions ====================================//
    
    // Swap SPARTA for TOKEN
    function buyTo(uint amount, address token, address member, uint minAmount) public {
        address _pool = iPOOLFACTORY(_DAO().POOLFACTORY()).getPool(token); // Get the pool address
        require(_pool != address(0), "!POOL"); // Must be a valid pool
        _handleTransferIn(BASE, amount, _pool); // Transfer SPARTA to pool
        uint fee;
        if(token != address(0)){
            (uint output, uint feey) = Pool(_pool).swapTo(token, member); // Swap SPARTA to TOKEN & tsf to user
            require(output > minAmount, '!RATE');
            fee = feey;
        } else {
            (uint output, uint feez) = Pool(_pool).swapTo(WBNB, address(this)); // Swap SPARTA to WBNB
            require(output > minAmount, '!RATE');
            _handleTransferOut(token, output, member); // Unwrap to BNB & tsf to user
            fee = feez;
        }
        _safetyTrigger(_pool);
        _getsDividend(_pool, fee); // Check for dividend & tsf it to pool
    }

    // Swap TOKEN for SPARTA
    function sellTo(uint amount, address token, address member, uint minAmount) public payable returns (uint){
        address _pool = iPOOLFACTORY(_DAO().POOLFACTORY()).getPool(token); // Get pool address
        require(_pool != address(0), "!POOL"); // Must be a valid pool
        _handleTransferIn(token, amount, _pool); // Transfer TOKEN to pool
        (uint output, uint fee) = Pool(_pool).swapTo(BASE, member); // Swap TOKEN to SPARTA & transfer to user
        require(output > minAmount, '!RATE');
        _safetyTrigger(_pool);
        _getsDividend(_pool, fee); // Check for dividend & tsf it to pool
        return fee;
    }

    // User performs a simple swap (to -> from)
    function swap(uint256 inputAmount, address fromToken, address toToken, uint256 minAmount) external payable{
        swapTo(inputAmount, fromToken, toToken, msg.sender, minAmount);
    }

    // Contract checks which swap function the user will require
    function swapTo(uint256 inputAmount, address fromToken, address toToken, address member, uint256 minAmount) public payable{
        require(fromToken != toToken); // Tokens must not be the same
        if(fromToken == BASE){
            buyTo(inputAmount, toToken, member, minAmount); // Swap SPARTA to TOKEN & tsf to user
        } else if(toToken == BASE) {
            sellTo(inputAmount, fromToken, member, minAmount); // Swap TOKEN to SPARTA & tsf to user
        } else {
            address _poolTo = iPOOLFACTORY(_DAO().POOLFACTORY()).getPool(toToken); // Get pool address
            require(_poolTo != address(0), "!POOL"); // Must be a valid pool
            uint feey = sellTo(inputAmount, fromToken, _poolTo, 0); // Swap TOKEN to SPARTA & tsf to pool
            address _toToken = toToken;
            if(toToken == address(0)){_toToken = WBNB;} // Handle BNB -> WBNB
            (uint _zz, uint _feez) = Pool(_poolTo).swapTo(_toToken, address(this)); // Swap SPARTA to TOKEN & tsf to ROUTER
            require(_zz > minAmount, '!RATE');
            uint fee = feey + _feez; // Get total slip fees
            _safetyTrigger(_poolTo);
            _getsDividend(_poolTo, fee); // Check for dividend & tsf it to pool
            _handleTransferOut(toToken, iBEP20(_toToken).balanceOf(address(this)), member); // Transfer TOKEN to user
        }
    }

    //================================ Swap Synths ========================================//
    
    // Swap TOKEN to Synth
    function swapAssetToSynth(uint inputAmount, address fromToken, address toSynth) external payable {
        require(inputAmount > 0, '!VALID'); // Must be a valid amount
        require(fromToken != toSynth); // Tokens must not be the same
        require(iRESERVE(_DAO().RESERVE()).globalFreeze() != true, '');
        address _pool = iSYNTH(toSynth).POOL(); // Get underlying pool address
        require(_pool != address(0), "!POOL"); // Must be a valid pool
        if(fromToken != BASE){
            sellTo(inputAmount, fromToken, address(this), 0); // Swap TOKEN to SPARTA & tsf to ROUTER
            iBEP20(BASE).transfer(_pool, iBEP20(BASE).balanceOf(address(this))); // Transfer SPARTA from ROUTER to pool
        } else {
            iBEP20(BASE).transferFrom(msg.sender, _pool, inputAmount); // Transfer SPARTA from ROUTER to pool
        }
        (, uint fee) = Pool(_pool).mintSynth(msg.sender); // Mint synths & tsf to user
        _safetyTrigger(_pool);
        _getsDividend(_pool, fee); // Check and tsf dividend to pool
    }
   
    // Swap Synth to TOKEN
    function swapSynthToAsset(uint inputAmount, address fromSynth, address toToken) external {
        require(inputAmount > 0, '!VALID'); // Must be a valid amount
        require(fromSynth != toToken); // Tokens must not be the same
        require(iRESERVE(_DAO().RESERVE()).globalFreeze() != true, '');
        address _poolIN = iSYNTH(fromSynth).POOL(); // Get underlying pool address
        address _pool = iPOOLFACTORY(_DAO().POOLFACTORY()).getPool(toToken); // Get TOKEN's relevant pool address
        require(_pool != address(0), "!POOL"); // Must be a valid pool
        iBEP20(fromSynth).transferFrom(msg.sender, _poolIN, inputAmount); // Transfer synth from user to pool
        uint outputAmount;
        uint fee;
        if(toToken == BASE){
            Pool(_poolIN).burnSynth(msg.sender); // Swap Synths for SPARTA & tsf to user
        } else {
            (outputAmount,fee) = Pool(_poolIN).burnSynth(address(this)); // Swap Synths to SPARTA & tsf to ROUTER
            if(toToken != address(0)){
                (, uint feey) = Pool(_pool).swapTo(toToken, msg.sender); // Swap SPARTA to TOKEN & transfer to user
                fee = feey + fee;
            } else {
                (uint outputAmountY, uint feez) = Pool(_pool).swapTo(WBNB, address(this)); // Swap SPARTA to WBNB & tsf to ROUTER
                _handleTransferOut(toToken, outputAmountY, msg.sender); // Unwrap to BNB & tsf to user
                fee = feez + fee;
            }
        }
        _safetyTrigger(_poolIN);
        _safetyTrigger(_pool);
        _getsDividend(_pool, fee); // Check and tsf dividend to pool
    }
    

    //============================== Token Transfer Functions ======================================//
    
    // Handle the transfer of assets into the pool
    function _handleTransferIn(address _token, uint256 _amount, address _pool) internal nonReentrant {
        require(_amount > 0, '!GAS');
        if(_token == address(0)){
            require((_amount == msg.value));
            (bool success, ) = payable(WBNB).call{value: _amount}(""); // Wrap BNB
            require(success, "!send");
            iBEP20(WBNB).transfer(_pool, _amount); // Transfer WBNB from ROUTER to pool
        } else {
            iBEP20(_token).transferFrom(msg.sender, _pool, _amount); // Transfer TOKEN to pool
        }
    }

    // Handle the transfer of assets out of the ROUTER
    function _handleTransferOut(address _token, uint256 _amount, address _recipient) internal nonReentrant {
        if(_amount > 0) {
            if (_token == address(0)) {
                iWBNB(WBNB).withdraw(_amount); // Unwrap WBNB to BNB
                (bool success, ) = payable(_recipient).call{value:_amount}("");  // Send BNB to recipient
                require(success, "!send");
            } else {
                iBEP20(_token).transfer(_recipient, _amount); // Transfer TOKEN to recipient
            }
        }
    }

    
    //============================= Token Dividends / Curated Pools =================================//
    // Check if fee should generate a dividend & send it to the pool
    function _getsDividend(address _pool, uint fee) internal {
        if(fee > 10**18 && iPOOLFACTORY(_DAO().POOLFACTORY()).isCuratedPool(_pool) == true){
            _addDividend(_pool, fee); // Check and tsf dividend to pool
        }
    }

    // Calculate the Dividend and transfer it to the pool
    function _addDividend(address _pool, uint256 _fees) internal {
        uint reserve = iBEP20(BASE).balanceOf(_DAO().RESERVE()); // Get SPARTA balance in the RESERVE contract
            if(reserve > 0){
                uint256 _dividendReward = (reserve * diviClaim) / curatedPoolsCount / 10000; // Get the dividend share 
                if((mapAddress_30DayDividends[_pool] + _fees) < _dividendReward){
                    _revenueDetails(_fees, _pool); // Add to revenue metrics
                    iRESERVE(_DAO().RESERVE()).grantFunds(_fees, _pool); // Transfer dividend from RESERVE to POOL
                    Pool(_pool).sync(); // Sync the pool balances to attribute the dividend to the existing LPers
                }
            }
    }

    function _revenueDetails(uint _fees, address _pool) internal {
        if(lastMonth == 0){
            lastMonth = block.timestamp;
        }
        if(block.timestamp <= lastMonth + 2592000){ // 30 days
            mapAddress_30DayDividends[_pool] = mapAddress_30DayDividends[_pool] + _fees;
        } else {
            lastMonth = block.timestamp;
            mapAddress_Past30DayPoolDividends[_pool] = mapAddress_30DayDividends[_pool];
            mapAddress_30DayDividends[_pool] = _fees;
            curatedPoolsCount = iPOOLFACTORY(_DAO().POOLFACTORY()).curatedPoolCount(); 
        }
    }
    
    //======================= Change Dividend Variables ===========================//

    function changeDiviClaim(uint _newDiviClaim) external onlyDAO {
        require(_newDiviClaim > 0 && _newDiviClaim < 5000, 'ZERO');
        diviClaim = _newDiviClaim;
    }

    function changeGlobalCap(uint _globalCap) external onlyDAO {	
        globalCAP = _globalCap;	
    }

    function changePoolCap(uint poolCAP, address _pool) external onlyDAO {
        Pool(_pool).setCAP(poolCAP);
    }

    function RTC(uint poolRTC, address _pool) external onlyDAO {
        Pool(_pool).RTC(poolRTC);
    }
    function changeMinimumSynth(uint newMinimum, address _pool) external onlyDAO {
        Pool(_pool).minimumSynth(newMinimum);
    }

    function _safetyTrigger(address _pool) internal {
        if(iPOOLFACTORY(_DAO().POOLFACTORY()).isCuratedPool(_pool)){
            if(Pool(_pool).freeze()){
                iRESERVE(_DAO().RESERVE()).setGlobalFreeze(true);   
            } 
        }
    }

    //================================== Helpers =================================//

    function currentPoolRevenue(address pool) external view returns(uint256) {
        return mapAddress_30DayDividends[pool];
    }

    function pastPoolRevenue(address pool) external view returns(uint256) {
        return mapAddress_Past30DayPoolDividends[pool];
    }
}