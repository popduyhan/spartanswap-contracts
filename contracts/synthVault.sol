// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.3;
import "./iBEP20.sol";
import "./iDAO.sol";
import "./iBASE.sol";
import "./iPOOL.sol";
import "./iSYNTH.sol";
import "./iUTILS.sol";
import "./iRESERVE.sol";
import "./iSYNTHFACTORY.sol";
import "./iPOOLFACTORY.sol";

contract SynthVault {
    address public BASE;
    address public DEPLOYER;

    uint256 public minimumDepositTime;
    uint256 public totalWeight;
    uint256 public erasToEarn;
    uint256 public blockDelay;
    uint256 public vaultClaim;
    address [] public stakedSynthAssets;

    // Only DAO can execute
     modifier onlyDAO() {
        require(msg.sender == _DAO().DAO() || msg.sender == DEPLOYER );
        _;
    }
    constructor(address _base) {
        BASE = _base;
        DEPLOYER = msg.sender;
        erasToEarn = 30;
        minimumDepositTime = 1;// needs to be 1hr
        blockDelay = 0;
        vaultClaim = 1000;
    }

    function _DAO() internal view returns(iDAO) {
         return iBASE(BASE).DAO();
       
    }
    mapping(address => mapping(address => uint256)) private mapMemberSynth_weight;
    mapping(address => uint256) private mapMemberTotal_weight;
    mapping(address => mapping(address => uint256)) private mapMemberSynth_deposit;

    mapping(address => mapping(address => uint256)) private mapMemberSynth_lastTime;
    mapping(address => uint256) private mapMember_depositTime;
    mapping(address => uint256) public lastBlock;
    mapping(address => bool) private isStakedSynth;
    mapping(address => mapping(address => bool)) private isSynthMember;

    // Events
    event MemberDeposits(
        address indexed synth,
        address indexed member,
        uint256 newDeposit,
        uint256 weight,
        uint256 totalWeight
    );
    event MemberWithdraws(
        address indexed synth,
        address indexed member,
        uint256 amount,
        uint256 weight,
        uint256 totalWeight
    );
    event MemberHarvests(
        address indexed synth,
        address indexed member,
        uint256 amount,
        uint256 weight,
        uint256 totalWeight
    );

    function setParams(uint256 one,uint256 two,uint256 three,uint256 four) external onlyDAO {
        erasToEarn = one;
        minimumDepositTime = two;
        blockDelay = three;
        vaultClaim = four;
    }

    //======================================DEPOSITS========================================//

    // Holders to deposit for Interest Payments
    function deposit(address synth, uint256 amount) external {
        depositForMember(synth, msg.sender, amount);
    }

    function depositForMember(address synth,address member,uint256 amount) public {
        require(iSYNTHFACTORY(_DAO().SYNTHFACTORY()).isSynth(synth), "!synth");
        require(iBEP20(synth).transferFrom(msg.sender, address(this), amount));
        _deposit(synth, member, amount);
    }
    function _deposit(address _synth, address _member,uint256 _amount) internal {
        if(!isStakedSynth[_synth]){
            isStakedSynth[_synth] = true;
            stakedSynthAssets.push(_synth);
        }
        mapMemberSynth_lastTime[_member][_synth] = block.timestamp + minimumDepositTime; // Synth Deposit Time
        mapMember_depositTime[_member] = block.timestamp + minimumDepositTime; //Deposit Time
        mapMemberSynth_deposit[_member][_synth] += _amount; // Record balance for member
        uint256 _weight = iUTILS(_DAO().UTILS()).calcSpotValueInBase(iSYNTH(_synth).LayerONE(), _amount); 
        mapMemberSynth_weight[_member][_synth] += _weight;
        mapMemberTotal_weight[_member] += _weight;
        totalWeight += _weight;
        isSynthMember[_member][_synth] = true;
        emit MemberDeposits(_synth, _member, _amount, _weight, totalWeight);
    }

    //====================================== HARVEST ========================================//

    function harvestAll() external returns (bool) {
        for(uint i = 0; i<stakedSynthAssets.length; i++){
            if(isSynthMember[msg.sender][stakedSynthAssets[i]] == true){
                uint256 reward = calcCurrentReward(stakedSynthAssets[i],msg.sender);
                if(reward > 0){
                    harvest(stakedSynthAssets[i]);
                } 
            }
        }
        return true;
    }

     function harvest(address synth) public {
        require(iSYNTHFACTORY(_DAO().SYNTHFACTORY()).isSynth(synth), "!synth");
        require(iRESERVE(_DAO().RESERVE()).emissions(), "!EMISSIONS");
        uint256 _weight;address _poolOUT;uint synthReward;
        uint256 reward = calcCurrentReward(synth,msg.sender);
        mapMemberSynth_lastTime[msg.sender][synth] = block.timestamp;
        address tokenSynth = iSYNTH(synth).LayerONE();
         if(tokenSynth == BASE){
           _poolOUT = iUTILS(_DAO().UTILS()).getDeepestPool();
         }else{
           _poolOUT = iPOOLFACTORY(_DAO().POOLFACTORY()).getPool(tokenSynth);
         }
           iRESERVE(_DAO().RESERVE()).grantFunds(reward, _poolOUT);
         if(tokenSynth == BASE){
            (synthReward,) = iPOOL(_poolOUT).mintBaseSynth(true,address(this));
            _weight = synthReward;
          }else{
            (synthReward,) = iPOOL(_poolOUT).mintTokenSynth(true,address(this));
            _weight = iUTILS(_DAO().UTILS()).calcSpotValueInBase(tokenSynth, synthReward);
         }
         mapMemberSynth_deposit[msg.sender][synth] += synthReward;
         mapMemberSynth_weight[msg.sender][synth] += _weight;
         mapMemberTotal_weight[msg.sender] += _weight;
         totalWeight += _weight;
         iSYNTH(synth).realise(_poolOUT);
         emit MemberHarvests(synth, msg.sender, reward, _weight, totalWeight);
    }

    function calcCurrentReward(address synth, address member) public view returns (uint256 reward){
        require((block.timestamp > mapMemberSynth_lastTime[member][synth]), "DepositTime"); // stops attacks
        uint256 _secondsSinceClaim = block.timestamp - mapMemberSynth_lastTime[member][synth]; // Get time since last claim
        uint256 _share = calcReward(synth, member);
        reward = (_share * _secondsSinceClaim) / iBASE(BASE).secondsPerEra();
        return reward;
    }

    function calcReward(address synth, address member) public view returns (uint256) {
        uint256 _weight = mapMemberSynth_weight[member][synth];
        uint256 _reserve = reserveBASE() / erasToEarn;
        uint256 _vaultReward = (_reserve * vaultClaim) / 10000;
        return iUTILS(_DAO().UTILS()).calcShare(_weight,totalWeight,_vaultReward); // Get member's share of that
    }

    //====================================== WITHDRAW ========================================//
    // Members to withdraw
    function withdraw(address synth, uint256 basisPoints) external returns (uint256 redeemedAmount) {
        redeemedAmount = _processWithdraw(synth, msg.sender, basisPoints);
        require(iBEP20(synth).transfer(msg.sender, redeemedAmount));
        return redeemedAmount;
    }

    function _processWithdraw( address _synth,address _member,uint256 _basisPoints) internal returns (uint256 synthReward) {
        require((block.timestamp > mapMember_depositTime[_member]), "DepositTime"); // stops attacks
        uint256 _principle = iUTILS(_DAO().UTILS()).calcPart(_basisPoints, mapMemberSynth_deposit[_member][_synth]); // share of deposits
        mapMemberSynth_deposit[_member][_synth] -= _principle;
        uint256 _weight = iUTILS(_DAO().UTILS()).calcPart( _basisPoints, mapMemberSynth_weight[_member][_synth]);
        mapMemberTotal_weight[_member] -= _weight;
        mapMemberSynth_weight[_member][_synth] -= _weight;
        totalWeight -= _weight; 
        emit MemberWithdraws(_synth,_member,synthReward,_weight,totalWeight);
        return (_principle + synthReward);
    }

    //================================ HELPERS ===============================//
    function reserveBASE() public view returns (uint256) {
        return iBEP20(BASE).balanceOf(_DAO().RESERVE());
    }

    function getMemberDeposit(address synth, address member) external view returns (uint256){
        return mapMemberSynth_deposit[member][synth];
    }

    function getMemberWeight(address member) external view returns (uint256) {
        return mapMemberTotal_weight[member];
    }
    function getStakeSynthLength() external view returns (uint256) {
        return stakedSynthAssets.length;
    }
    function getMemberLastTime(address member) external view returns (uint256) {
        return mapMember_depositTime[member];
    }
    function getMemberLastSynthTime(address synth, address member) external view returns (uint256){
        return mapMemberSynth_lastTime[member][synth];
    }
    function getMemberSynthWeight(address synth, address member) external view returns (uint256) {
        return mapMemberSynth_weight[member][synth];
    }


}
