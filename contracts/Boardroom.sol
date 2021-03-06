// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import './lib/AdminRole.sol';
import './lib/Safe112.sol';
import './utils/ContractGuard.sol';

/**
 * @title 股份质押合约
 */
contract shareWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    /// @notice GoCash Token合约地址
    IERC20 public share;
    /// @dev 质押总量
    uint256 private _totalSupply;
    /// @dev 余额映射
    mapping(address => uint256) private _balances;

    /**
     * @dev 返回总量
     * @return 总量
     */
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev 返回账户余额
     * @param account 账户地址
     * @return 余额
     */
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev 把share抵押到Boardroom
     * @param amount 质押数量
     */
    function stake(uint256 amount) public virtual {
        // 总量增加
        _totalSupply = _totalSupply.add(amount);
        // 余额映射增加
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        // 将share发送到当前合约
        share.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev 从Boardroom赎回share
     * @param amount 赎回数量
     */
    function withdraw(uint256 amount) public virtual {
        // 用户的总质押数量
        uint256 directorShare = _balances[msg.sender];
        // 确认总质押数量大于取款数额
        require(
            directorShare >= amount,
            'Boardroom: withdraw request greater than staked amount'
        );
        // 总量减少
        _totalSupply = _totalSupply.sub(amount);
        // 余额减少
        _balances[msg.sender] = directorShare.sub(amount);
        // 将share发送给用户
        share.safeTransfer(msg.sender, amount);
    }
}

/**
 * @title GoCash Cash Boardroom合约
 * 实现功能：
 * 1.share抵押到Boardroom，从Boardroom赎回share
 * 2.每次Epoch时，Admin计算cash增发的数量(计算公式在Treasury合约)，
 * 并把cash奖励分配给把share抵押到Boardroom的董事
 * 注解：TimBear 20210107
 */
contract Boardroom is shareWrapper, ContractGuard, AdminRole {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Safe112 for uint112;

    /* ========== PARAMETERS =============== */

    /// @notice 取款锁定周期
    uint256 public withdrawLockupEpochs = 4;
    /// 奖励锁定周期
    uint256 public rewardLockupEpochs = 0;
    // 整周期开始时间
    uint256 public epochAlignTimestamp = 1608883200;
    // 周期时长
    uint256 public epochPeriod = 28800;

    /* ========== DATA STRUCTURES ========== */

    /// @notice 结构体：董事会席位
    struct Boardseat {
        uint256 lastSnapshotIndex; // 最后快照索引
        uint256 rewardEarned; // 未领取的奖励数量
        uint256 epochTimerStart; // 周期开始时间
    }

    /// @notice 结构体：董事会快照
    struct BoardSnapshot {
        uint256 time; // 区块高度
        uint256 rewardReceived; // 收到的奖励
        uint256 rewardPerShare; // 每股奖励数量
    }

    /* ========== STATE VARIABLES ========== */
    /// @dev GoCash Cash合约地址
    IERC20 private cash;

    /// @dev 映射：每个地址对应每个董事会席位，即一个地址对应一个董事(结构体)
    mapping(address => Boardseat) private directors;
    /// @dev 董事会快照数组
    BoardSnapshot[] private boardHistory;

    /* ========== CONSTRUCTOR ========== */

    /**
     * @dev 构造函数
     * @param _cash GoCash Cash合约地址
     * @param _share GoCash Token合约地址
     */
    constructor(IERC20 _cash, IERC20 _share) public {
        cash = _cash;
        share = _share;
        // 创建董事会快照
        BoardSnapshot memory genesisSnapshot = BoardSnapshot({
            time: block.number,
            rewardReceived: 0,
            rewardPerShare: 0
        });
        //董事会的创世快照推入数组
        boardHistory.push(genesisSnapshot);
    }

    /* ========== Modifiers =============== */
    /// @notice 修饰符：需要调用者在Boardroom的抵押数量大于0
    modifier directorExists {
        require(
            balanceOf(msg.sender) > 0,
            'Boardroom: The director does not exist'
        );
        _;
    }

    /// @notice 修饰符：更新指定用户的奖励(cash)
    /// @param director 成员地址
    modifier updateReward(address director) {
        // 如果成员地址不是0地址
        if (director != address(0)) {
            // 根据成员地址实例化董事会席位
            Boardseat memory seat = directors[director];
            // 已获取奖励数量 = 计算董事可提取的总奖励
            seat.rewardEarned = earned(director);
            // 最后快照索引 = 董事会快照数组长度-1
            seat.lastSnapshotIndex = latestSnapshotIndex();
            // 重新赋值
            directors[director] = seat;
        }
        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters
    // 一些只读方法：获取快照信息
    /**
     * @dev 最后快照索引
     * @return 索引值
     */
    function latestSnapshotIndex() public view returns (uint256) {
        // 董事会数组长度-1
        return boardHistory.length.sub(1);
    }

    /**
     * @dev 董事会最后一次快照具体内容
     * @return 董事会快照结构体
     */
    function getLatestSnapshot() internal view returns (BoardSnapshot memory) {
        return boardHistory[latestSnapshotIndex()];
    }

    /**
     * @dev 返回指定用户的董事会席位最后快照id
     * @param director 用户地址
     * @return 最后快照id
     */
    function getLastSnapshotIndexOf(address director)
        public
        view
        returns (uint256)
    {
        return directors[director].lastSnapshotIndex;
    }

    /**
     * @dev 返回指定用户的董事会席位最后快照id对应的董事会内容
     * @param director 用户地址
     * @return 董事会快照结构体
     */
    function getLastSnapshotOf(address director)
        internal
        view
        returns (BoardSnapshot memory)
    {
        return boardHistory[getLastSnapshotIndexOf(director)];
    }

    /**
     * @dev 获取当前周期时间戳
     * @return 时间戳
     */
    function getCurrentEpochTimestamp() public view returns(uint256) {
        // 整周期时间戳 + (取整((当前时间戳 - 整周期时间戳) / 周期时长) * 周期时长)
        return epochAlignTimestamp.add(
                block.timestamp
                .sub(epochAlignTimestamp)
                .div(epochPeriod)
                .mul(epochPeriod)
            );
    }

    /**
     * @dev 获取可以取款的时间
     * @param director 用户地址
     * @return 时间戳
     */
    function getCanWithdrawTime(address director) public view returns(uint256) {
        // 用户的周期开始时间 + 取款锁定周期 * 周期时长
        return directors[director].epochTimerStart.add(
                    withdrawLockupEpochs.mul(epochPeriod)
                );
    }

    /**
     * @dev 获取可以收获的时间
     * @param director 用户地址
     * @return 时间戳
     */
    function getCanClaimTime(address director) public view returns(uint256) {
        // 用户的周期开始时间 + 奖励锁定周期 * 周期时长
        return directors[director].epochTimerStart.add(
                    rewardLockupEpochs.mul(epochPeriod)
                );
    }

    /**
     * @dev 获取是否可以取款
     * @param director 用户地址
     * @return 布尔
     */
    function canWithdraw(address director) public view returns (bool) {
        return getCanWithdrawTime(director) <= getCurrentEpochTimestamp();
    }

    /**
     * @dev 获取是否可以收获
     * @param director 用户地址
     * @return 布尔
     */
    function canClaimReward(address director) public view returns (bool) {
        return getCanClaimTime(director) <= getCurrentEpochTimestamp();
    }

    // =========== Director getters

    /**
     * @dev 返回董事会最后一次快照具体内容中的每股奖励数量
     * @return 每股奖励数量
     */
    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    /**
     * @dev 计算董事可提取的总奖励(cash)
     * @param director 用户地址
     * @return cash数量
     */
    function earned(address director) public view returns (uint256) {
        // 返回董事会最后一次快照具体内容中的每股奖励数量
        uint256 latestRPS = rewardPerShare();
        // 返回指定用户的董事会席位最后快照id对应的董事会内容中的每股奖励数量
        uint256 storedRPS = getLastSnapshotOf(director).rewardPerShare;

        //      (最新快照中每share可获得的cash数量
        //    - 上次快照中每share可获得的cash数量)
        //    x 董事抵押的share个数
        //    + 董事未提取的奖励
        //---------------------------------
        //      董事可提取的总奖励
        return
            balanceOf(director).mul(latestRPS.sub(storedRPS)).div(1e18).add(
                directors[director].rewardEarned
            );
    }

    /* ========== GOVERNANCE ================== */

    /**
     * @dev 设置锁定数值
     * @param _withdrawLockupEpochs 取款锁定周期
     * @param _rewardLockupEpochs  奖励锁定周期
     * @param _epochAlignTimestamp  整周期时间戳
     * @param _epochPeriod  周期时长
     */
    function setLockUp(
        uint256 _withdrawLockupEpochs, 
        uint256 _rewardLockupEpochs,
        uint256 _epochAlignTimestamp, 
        uint256 _epochPeriod
    ) 
        external 
        onlyAdmin 
    {
        // 确认取款锁定周期 >= 奖励锁定周期 && 取款锁定周期 < 21
        require(
            _withdrawLockupEpochs >= _rewardLockupEpochs 
            && _withdrawLockupEpochs <= 21, 
            "LockupEpochs: out of range"
        );
        // 确认周期时长 < 1天
        require(_epochPeriod <= 1 days, "EpochPeriod: out of range");
        // 确认 整周期时间戳 + 周期时长 * 2 < 当前时间
        require(
            _epochAlignTimestamp.add(_epochPeriod.mul(2)) < block.timestamp, 
            "EpochAlignTimestamp: too late"
        ); 
        // 变量赋值
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
        epochAlignTimestamp = _epochAlignTimestamp;
        epochPeriod = _epochPeriod;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @dev 把share抵押到Boardroom
     * @param amount 质押数量
     */
    function stake(uint256 amount)
        public
        override
        onlyOneBlock
        updateReward(msg.sender)
    {
        // 确认数量大于0
        require(amount > 0, 'Boardroom: Cannot stake 0');
        // 调用父级质押方法
        super.stake(amount);
        // 用户周期开始时间 = 获取当前周期时间戳
        directors[msg.sender].epochTimerStart = getCurrentEpochTimestamp();
        //触发抵押事件
        emit Staked(msg.sender, amount);
    }

    /**
     * @dev 从Boardroom赎回share
     * @param amount 赎回数量
     */
    function withdraw(uint256 amount)
        public
        override
        onlyOneBlock
        directorExists
        updateReward(msg.sender)
    {
        // 确认数量大于0
        require(amount > 0, 'Boardroom: Cannot withdraw 0');
        // 确认可以取款
        require(canWithdraw(msg.sender), "Boardroom: still in withdraw lockup");
        // 调用父级赎回方法
        super.withdraw(amount);
        //触发赎回事件
        emit Withdraw(msg.sender, amount);
    }

    /**
     * @dev 从Boardroom赎回share，并提取奖励
     */
    function exit() external {
        // 调用赎回方法
        withdraw(balanceOf(msg.sender));
        // 调用获取奖励方法
        claimReward();
    }

    /**
     * @dev 从Boardroom收获奖励，奖励为cash
     * @notice 修改器中先更新了指定用户的奖励(cash)
     */
    function claimReward() public updateReward(msg.sender) {
        //更新董事的奖励后，获取奖励数量
        uint256 reward = directors[msg.sender].rewardEarned;
        // 如果数量大于0
        if (reward > 0) {
            // 确认可以收获奖励
            require(canClaimReward(msg.sender), "Boardroom: still in claimReward lockup");
            //把未领取的奖励数量重设为0
            directors[msg.sender].rewardEarned = 0;
            // 将奖励发送给用户
            cash.safeTransfer(msg.sender, reward);
            //触发完成奖励事件
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @dev 分配铸币，即分配每个share可以获取多少cash，仅Admin有权限控制
     * @param amount 分配数量
     * @notice 每Epoch增发多少cash只由Admin决定,具体计算公式在Treasury合约
     */
    function allocateSeigniorage(uint256 amount)
        external
        onlyOneBlock
        onlyAdmin
    {
        // 确认分配数量大于0
        require(amount > 0, 'Boardroom: Cannot allocate 0');
        // 确认质押总量大于0
        require(
            totalSupply() > 0,
            'Boardroom: Cannot allocate when totalSupply is 0'
        );

        // 上一次每股奖励数量 = 董事会最后一次快照具体内容中的每股奖励数量
        uint256 prevRPS = rewardPerShare();
        // 下一次每股奖励数量 =  上一次每股奖励数量 + 分配数量 * 1e18 / 质押总量
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));
        //注意：每次快照记录的都为总量(累积量)，计算每Epoch新奖励的数量时要用增量(做减法)
        // 实例化董事会快照
        BoardSnapshot memory newSnapshot = BoardSnapshot({
            time: block.number, // 当前区块高度
            rewardReceived: amount, // 收到的分配数量
            rewardPerShare: nextRPS // 每股奖励数量
        });
        //更新快照推入数组
        boardHistory.push(newSnapshot);

        //把增发的cash数量发送到本合约中，增发数量由Admin决定
        cash.safeTransferFrom(msg.sender, address(this), amount);
        //触发cash增发至董事会事件
        emit RewardAdded(msg.sender, amount);
    }

    /**
     * @dev 拯救其它资产
     * @param _token Token地址
     * @param _amount 数量
     * @param _to 目标地址
     * @notice 误转到合约的其它资产可以取出
     */
    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyAdmin {
        // do not allow to drain core tokens
        require(address(_token) != address(cash), 'cash');
        require(address(_token) != address(share), 'share');
        _token.safeTransfer(_to, _amount);
    }

    /* ========== EVENTS ========== */
    /**
     * @dev 事件: 质押
     * @param user 用户地址
     * @param amount 质押数量
     */
    event Staked(address indexed user, uint256 amount);
    /**
     * @dev 事件: 赎回
     * @param user 用户地址
     * @param amount 赎回数量
     */
    event Withdraw(address indexed user, uint256 amount);
    /**
     * @dev 事件: 支付奖励
     * @param user 用户地址
     * @param reward 奖励数量
     */
    event RewardPaid(address indexed user, uint256 reward);
    /**
     * @dev 事件: 奖励增加
     * @param user 用户地址
     * @param reward 奖励数量
     */
    event RewardAdded(address indexed user, uint256 reward);
}
