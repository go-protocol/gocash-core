// SPDX-License-Identifier: MIT

/**
 *Boardroom合约中BasisDollar相对于BasisCash的修改：
 *在Boardroom中，每withdraw一次增加5Epochs的锁仓时间，每reward一次增加3Epochs的锁仓时间
 *即增发后不能实时提取，舒缓早期的抛售压力
 */

pragma solidity 0.6.12;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

import './utils/ContractGuard.sol';
import './interfaces/IBasisAsset.sol';
import './interfaces/ITreasury.sol';

contract ShareWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public share;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function stake(uint256 amount) public virtual {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        share.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public virtual {
        uint256 directorShare = _balances[msg.sender];
        require(
            directorShare >= amount,
            'Boardroom: withdraw request greater than staked amount'
        );
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = directorShare.sub(amount);
        share.safeTransfer(msg.sender, amount);
    }
}

contract Boardroom is ShareWrapper, ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Boardseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct BoardSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    IERC20 public dollar;
    ITreasury public treasury;

    mapping(address => Boardseat) public directors;
    BoardSnapshot[] public boardHistory;

    // protocol parameters - https://docs.basisdollar.fi/ProtocolParameters
    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(
            operator == msg.sender,
            'Boardroom: caller is not the operator'
        );
        _;
    }

    modifier directorExists {
        require(
            balanceOf(msg.sender) > 0,
            'Boardroom: The director does not exist'
        );
        _;
    }

    modifier updateReward(address director) {
        if (director != address(0)) {
            Boardseat memory seat = directors[director];
            seat.rewardEarned = earned(director);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            directors[director] = seat;
        }
        _;
    }

    modifier notInitialized {
        require(!initialized, 'Boardroom: already initialized');
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        IERC20 _dollar,
        IERC20 _share,
        ITreasury _treasury
    ) public notInitialized {
        dollar = _dollar;
        share = _share;
        treasury = _treasury;

        BoardSnapshot memory genesisSnapshot = BoardSnapshot({
            time: block.number,
            rewardReceived: 0,
            rewardPerShare: 0
        });
        boardHistory.push(genesisSnapshot);

        //BasisDollar相对于BasisCash的修改：在Boardroom中，每withdraw一次增加5Epochs的锁仓时间，每reward一次增加3Epochs的锁仓时间
        //即增发后不能实时提取，舒缓早期的抛售压力
        withdrawLockupEpochs = 5; // Lock for 4 epochs before release withdraw
        rewardLockupEpochs = 3; // Lock for 2 epochs before release claimReward

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setLockUp(
        uint256 _withdrawLockupEpochs,
        uint256 _rewardLockupEpochs
    ) external onlyOperator {
        require(
            _withdrawLockupEpochs >= _rewardLockupEpochs &&
                _withdrawLockupEpochs <= 14,
            '_withdrawLockupEpochs: out of range'
        ); // <= 1 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256) {
        return boardHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (BoardSnapshot memory) {
        return boardHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address director)
        public
        view
        returns (uint256)
    {
        return directors[director].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address director)
        internal
        view
        returns (BoardSnapshot memory)
    {
        return boardHistory[getLastSnapshotIndexOf(director)];
    }

    function canWithdraw(address director) external view returns (bool) {
        return
            directors[director].epochTimerStart.add(withdrawLockupEpochs) <=
            treasury.epoch();
    }

    function canClaimReward(address director) external view returns (bool) {
        return
            directors[director].epochTimerStart.add(rewardLockupEpochs) <=
            treasury.epoch();
    }

    // =========== Director getters

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address director) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(director).rewardPerShare;

        return
            balanceOf(director).mul(latestRPS.sub(storedRPS)).div(1e18).add(
                directors[director].rewardEarned
            );
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount)
        public
        override
        onlyOneBlock
        updateReward(msg.sender)
    {
        require(amount > 0, 'Boardroom: Cannot stake 0');
        super.stake(amount);
        directors[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount)
        public
        override
        onlyOneBlock
        directorExists
        updateReward(msg.sender)
    {
        require(amount > 0, 'Boardroom: Cannot withdraw 0');
        //withdraw时需要满足锁仓时间
        require(
            directors[msg.sender].epochTimerStart.add(withdrawLockupEpochs) <=
                treasury.epoch(),
            'Boardroom: still in withdraw lockup'
        );
        claimReward();
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = directors[msg.sender].rewardEarned;
        if (reward > 0) {
            //reward时需要满足锁仓时间
            require(
                directors[msg.sender].epochTimerStart.add(rewardLockupEpochs) <=
                    treasury.epoch(),
                'Boardroom: still in reward lockup'
            );
            directors[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
            directors[msg.sender].rewardEarned = 0;
            dollar.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     *@notice 董事会中把铸币分配给share抵押者
     */
    function allocateSeigniorage(uint256 amount)
        external
        onlyOneBlock
        onlyOperator
    {
        require(amount > 0, 'Boardroom: Cannot allocate 0');
        require(
            totalSupply() > 0,
            'Boardroom: Cannot allocate when totalSupply is 0'
        );

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        BoardSnapshot memory newSnapshot = BoardSnapshot({
            time: block.number,
            rewardReceived: amount,
            rewardPerShare: nextRPS
        });
        boardHistory.push(newSnapshot);

        dollar.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(msg.sender, amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(dollar), 'dollar');
        require(address(_token) != address(share), 'share');
        _token.safeTransfer(_to, _amount);
    }
}
