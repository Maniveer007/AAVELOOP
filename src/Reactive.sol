// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.0;

import '@reactive-lib/src/interfaces/IReactive.sol';
import '@reactive-lib/src/abstract-base/AbstractReactive.sol';
import '@reactive-lib/src/interfaces/ISystemContract.sol';

contract ReactiveContract is IReactive, AbstractReactive {

    uint256 public ChainId;
    address public immutable owner;

    uint64 private constant GAS_LIMIT = 1000000;

    address private AaveLoop;
    uint256 constant LoopStarted_topic_0 = 0xa21987f2a0b3ee33e728104eccc83b9c12b8218bef24d27014407225069ffcf6  ;
    uint256 constant LoopIterated_topic_0 = 0x0c748f51faf4bdb31cc0225ca94ee877ec68daf5e1a52b8d576a383c2b3a04bd ;

    uint MIN_BORROW_AMOUNT;
    uint BORROW_RATE_PER_STEP;
    uint TARGET_TVL;


    constructor(
        address _service,
        uint256 _chainId,
        address _aaveLoop
    ) payable {
        service = ISystemContract(payable(_service));

        ChainId = _chainId;
        AaveLoop = _aaveLoop;
        owner = msg.sender;

        if (!vm) {
            service.subscribe(
                ChainId,
                AaveLoop,
                LoopStarted_topic_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            service.subscribe(
                ChainId,
                AaveLoop,
                LoopIterated_topic_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }    

    function react(LogRecord calldata log) external vmOnly {

        if (log.topic_0 == LoopStarted_topic_0) {
            (
            ,,uint bps,uint256 minBorrowAmount
            ,,,uint256 targetTvl
            )= abi.decode(log.data, (address, uint256, uint16, uint256, uint16, uint256, uint));

            MIN_BORROW_AMOUNT=minBorrowAmount;
            BORROW_RATE_PER_STEP = bps;
            TARGET_TVL=targetTvl;

            bytes memory payload = abi.encodeWithSignature("onReactiveCallback(address)", address(0));
            emit Callback(ChainId, AaveLoop, GAS_LIMIT, payload);
        }

        if(log.topic_0 == LoopIterated_topic_0) {
            (uint256 iterationCollateralBase_inAssetTokens, uint256 iterationDebtBase_inAssetTokens) = abi.decode(log.data,(uint,uint));

            if(iterationCollateralBase_inAssetTokens<TARGET_TVL && ((iterationDebtBase_inAssetTokens*BORROW_RATE_PER_STEP)/10000) >= MIN_BORROW_AMOUNT){
                bytes memory payload = abi.encodeWithSignature("onReactiveCallback(address)", address(0));
                emit Callback(ChainId, AaveLoop, GAS_LIMIT, payload);
            }
            
        }

    }

    function withdraw() public onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }
}

// 0x9E9aCc2E250083fC921e7f75E718fc117113Ee73
//    