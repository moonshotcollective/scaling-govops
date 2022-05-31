// SPDX-License-Identifier: Apache-2.0
/**
                            ,*.
                          .**,
                          ,***.
                    .,.   ,***,
                  .**,    *****.
                .****.    ,*****,
              .******,     ,******,
            .*******.       .********,              .
          ,******.            .*************,,*****.
        ,*****.        ,,.        ,************,.
    .,****.         ,*****,
    ,***,          ,*******,.              ..
  ,**,          .*******,.       ,********.
              .******,.       .********,
            .*****,         .*******,
          ,****,          .******,
        ,***,.          .*****,
      ,**,.           ./***,
    ,,             .***,
                  .**,
                    Moonshot Collective
            https://github.com/moonshotcollective
*/
pragma solidity ^0.8.13;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Arrays.sol";
import "./libs/ABDKMath64x64.sol";

/// @title Conviction Voting Contract
/// @author QEDK, Jaxcoder
/// @notice Explain to an end user what this does
/// @dev Explain to a developer any extra details
contract ConvictionVoting is Ownable {
    using ABDKMath64x64 for uint256;
    using SafeERC20 for IERC20;
    using Arrays for uint256[];

    error BadGaugeId();
    error EmptyCount();

    struct Gauge {
        uint256 id;
        uint256 currentConvictionId;
        uint256 totalCovictionStaked;
        mapping(uint256 => Conviction) convictions;
        mapping(address => uint256[]) convictionsByUser;
    }

    struct Conviction {
        address userAddress;
        uint256 amount;
        uint256 timestamp;
    }

    uint256 public currentGaugeId;
    uint256 public convictionThreshold;
    uint256 public effectiveSupply;
    uint256 public minimumConviction;

    /// @notice Mapping of all gauges structs
    mapping(uint256 => Gauge) public gauges;

    /// @notice Mapping of conviction scores for a user
    mapping(address => uint256) public scores;

    IERC20 public token;

    event NewGauge(uint256 indexed id);
    event AddConviction(
        uint256 indexed gaugeId,
        uint256 indexed convictionId,
        address indexed user,
        uint256 amount
    );
    event RemoveConviction(
        uint256 indexed gaugeId,
        uint256 indexed convictionId,
        address indexed user,
        uint256 amount
    );

    constructor(address newToken, address owner) {
        token = IERC20(newToken);
        _transferOwnership(owner);
    }

    /// @notice Adds a new gauge with no convictions
    function addGauge() external onlyOwner {
        uint256 current = ++currentGaugeId;
        Gauge storage gauge = gauges[current]; // gauges start from 1...
        gauge.id = current;

        emit NewGauge(current);
    }

    /// @notice Adds conviction to a gauge
    /// @param user The address of the user adding conviction
    /// @param gaugeId The ID of the gauge where the user is adding their conviction
    /// @param amount The amount of GTC being added as conviction (not the weight/score)
    function addConviction(
        address user,
        uint256 gaugeId,
        uint256 amount
    ) external returns (uint256 totalConvictions) {
        Gauge storage gauge = gauges[gaugeId];
        if (gauge.id == 0) revert BadGaugeId();
        uint256 convictionId = gauge.currentConvictionId++; // convictionId starts from 0...
        Conviction storage convictions = gauge.convictions[convictionId];
        convictions.userAddress = user;
        convictions.amount = amount;
        convictions.timestamp = block.timestamp;
        gauge.convictionsByUser[user].push(convictionId);
        gauge.totalCovictionStaked += amount;
        token.safeTransferFrom(user, address(this), amount);

        emit AddConviction(gaugeId, convictionId, user, amount);
    }

    /// @notice removes conviction by id(s)
    /// @param gaugeId The ID of the gauge
    /// @param count Number of convictions to remove
    /// @param oldestFirst Start removing from the left of the conviction array
    /// @param convictions Array of current conviction values
    /// @dev We use the existing array as calldata to remove some pesky SLOADs, take care to be accurate!
    function removeConvictionByIds(
        uint256 gaugeId,
        uint256 count,
        bool oldestFirst,
        address receiver,
        uint256[] calldata convictions // where does this come from?
    ) external {
        Gauge storage gauge = gauges[gaugeId];
        if (gauge.id == 0) revert BadGaugeId();
        if (count == 0) revert EmptyCount();
        uint256 returnAmount = 0;
        if (oldestFirst) {
            for (uint256 i = 0; i <= count; i++) {
                require(
                    gauge.convictions[convictions[i]].userAddress == msg.sender,
                    "ONLY_VOTER"
                );
                returnAmount += gauge.convictions[convictions[i]].amount;
                delete gauge.convictions[convictions[i]];
            }
            gauge.convictionsByUser[msg.sender] = uint256[](
                convictions[:count]
            );
        } else {
            for (
                uint256 i = convictions.length - 1;
                i >= convictions.length - count;
                i--
            ) {
                require(
                    gauge.convictions[convictions[i]].userAddress == msg.sender,
                    "ONLY_VOTER"
                );
                returnAmount += gauge.convictions[convictions[i]].amount;
                delete gauge.convictions[convictions[i]];
            }
            gauge.convictionsByUser[msg.sender] = uint256[](
                convictions[:count]
            );
        }
        token.safeTransfer(receiver, returnAmount);
    }

    /// @notice Remove conviction by amount
    /// @param gaugeId The ID of the gauge
    /// @param receiver Address to refund convicted tokens
    /// @param convictions Array of current conviction values
    /// @dev We use the existing array as calldata to remove some pesky SLOADs, take care to be accurate!
    function removeConvictionByAmount(
        uint256 gaugeId,
        uint256 amount,
        address receiver,
        uint256[] calldata convictions
    ) external {
        Gauge storage gauge = gauges[gaugeId];
        if (gauge.id != 0) revert BadGaugeId();
        uint256 convictionRemoved = 0;
        uint256 idx = 0;
        for (uint256 i = 0; i < convictions.length; i++) {
            Conviction memory conviction = gauge.convictions[convictions[i]];
            require(conviction.userAddress == msg.sender, "ONLY_VOTER");
            convictionRemoved += conviction.amount;
            if (convictionRemoved == amount) {
                delete gauge.convictions[convictions[i]];
                idx = i;
                break;
            } else if (convictionRemoved > amount) {
                gauge.convictions[convictions[i]].amount =
                    convictionRemoved -
                    amount;
                idx = i + 1;
                break;
            }
            delete gauge.convictions[convictions[i]];
        }
        gauge.convictionsByUser[msg.sender] = uint256[](convictions[:idx]);
        token.safeTransfer(receiver, amount);
    }

    /// @notice Remove all convictions for an address
    /// @param gaugeId Gauge id to calculate score for
    /// @param receiver Address to return tokens to
    function removeAllConvictions(uint256 gaugeId, address receiver) external {
        Gauge storage gauge = gauges[gaugeId];
        if (gauge.id == 0) revert BadGaugeId();
        uint256 returnAmount = 0;
        uint256[] memory convictions = gauge.convictionsByUser[msg.sender];
        for (uint256 i = 0; i < convictions.length; i++) {
            returnAmount += gauge.convictions[convictions[i]].amount;
            gauge.totalCovictionStaked -= returnAmount;
            delete gauge.convictions[convictions[i]];
        }
        delete gauge.convictionsByUser[msg.sender];
        token.safeTransfer(receiver, returnAmount);
    }

    /// @notice Get the score for a gauge
    /// @param gaugeId the id of the gauge
    function totalStakedForGauge(
        uint256 gaugeId
    )
        external
        view
        returns (uint256 totalStaked)
    {
        Gauge storage gauge = gauges[gaugeId];

        totalStaked = gauge.totalCovictionStaked;

        return totalStaked;
    }

    /// @notice Calculate conviction score for a gauge
    /// @param gaugeId Gauge id to calculate score for
    /// @return score Calculated score
    function getConvictionScoreForGauge(uint256 gaugeId)
        external
        view
        returns (uint256 score)
    {
        Gauge storage gauge = gauges[gaugeId];
        uint256 length = gauge.currentConvictionId;
        for (uint256 i = 0; i < length; i++) {
            Conviction memory conviction = gauge.convictions[i];
            if (conviction.userAddress == address(0)) {
                continue; // conviction was removed
            }
            uint256 x1 = conviction.amount.sqrtu();
            uint256 x2 = (block.timestamp - conviction.timestamp)**2;
            score += x1 * x2;
        }

        return score;
    }

    /// @notice Calculate conviction score for an user on a gauge
    /// @param gaugeId Gauge id to calculate score for
    /// @param user User address to calculate score for
    /// @return score Calculated score
    function getConvictionScore(uint256 gaugeId, address user)
        external
        view
        returns (uint256 score)
    {
        Gauge storage gauge = gauges[gaugeId];
        uint256[] memory convictions = gauge.convictionsByUser[user];
        for (uint256 i = 0; i < convictions.length; i++) {
            uint256 x1 = uint256(
                ABDKMath64x64.sqrtu(gauge.convictions[i].amount)
            );
            uint256 x2 = (block.timestamp - gauge.convictions[i].timestamp)**2;
            score += x1 * x2;
        }

        return score;
    }

    function getGaugeDetails(uint256 gaugeId) public view returns (uint256) {
        Gauge storage gauge = gauges[gaugeId];

        return gauge.totalCovictionStaked;
    }

    function totalStaked() public view returns (uint256) {
        uint256 staked = token.balanceOf(address(this));

        return staked;
    }

    /// @notice get a users conviction score for a gauge
    /// @param gaugeId the id of the gauge
    /// @param user the address of the user
    /// @return userCovictions the users convictions for a gauge
    function getConvictionsByUser(uint256 gaugeId, address user)
        external
        view
        returns (uint256[] memory userCovictions)
    {
        Gauge storage gauge = gauges[gaugeId];
        return gauge.convictionsByUser[user];
    }

    /// @notice Get a user's staked amount
    /// @param gaugeId the ID of the gauge
    /// @param user The address of the user
    /// @return stake The user's total stake for a gauge in token units
    function getStakeByUser(uint256 gaugeId, address user)
        public
        view
        returns (uint256 stake)
    {
        Gauge storage gauge = gauges[gaugeId];
        uint256[] memory convictionIds = gauge.convictionsByUser[user];
        uint256 length = convictionIds.length;
        for (uint256 i = 0; i < length; ++i) {
            Conviction memory conviction = gauge.convictions[convictionIds[i]];
            stake += conviction.amount;
        }
    }

    /// @notice get a total conviction score for a gauge
    /// @param gaugeId the id of the gauge
    /// @return convictionTotal the total conviction for that gauge
    function getTotalConvictionForGauge(uint256 gaugeId)
        public
        view
        returns (uint256 convictionTotal)
    {
        Gauge storage gauge = gauges[gaugeId];
        Conviction storage convictions = gauge.convictions[gaugeId];
        convictionTotal = 0;
        //for(uint i = 0; i < gauge.convictions[gaugeId].length; i++) {
        // add them upp
        //}

        return convictionTotal;
    }

    /// @notice Calculates the minimum conviction a user can commit
    /// @param gaugeId the id of the gauge
    /// @return convictionReqd The amount of tokens required to add conviction to a gauge
    function calculateMinimumConviction(uint256 gaugeId)
        external
        view
        returns (uint256)
    {
        uint256 convictionReqd = 0;

        return convictionReqd;
    }

    /// @notice playing with thresholds for proposals
    /// @dev Formula: ρ * totalStaked / (1 - a) / (β - requestedAmount / total)**2
    /// For the Solidity implementation we amplify ρ and β and simplify the formula:
    /// wieght = ρ * D
    /// maxRatio = β * D
    /// decay = a * D
    /// threshold = weight * totalStaked * D ** 2 * funds ** 2 / (D - decay) / (maxRatio * funds - requestedAmount * D) ** 2
    /// @param requestedAmount Requested amount of tokens for a certain proposal
    /// @return threshold The threshold a proposal's conviction should surpass in order to be able to execute it.
    function calculateThreshold(uint256 requestedAmount)
        external
        view
        returns (uint256 threshold)
    {
        // get the balance of the vault, GTC. Using address(this) as a placeholder
        uint256 funds = token.balanceOf(address(this));
    }
}
