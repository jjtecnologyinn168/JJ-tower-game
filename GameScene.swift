import SwiftUI
import SpriteKit
import GameplayKit

// MARK: - 数据结构与数学组件

/// 3D 空间 bounding box 在 2D 投影面与伪 3D 深度轴的映射表达
struct CyberVolume {
    var position: SIMD3<Float> // x: 赛道(0,1,2), y: 高度, z: 距离(深度)
    var size: SIMD3<Float>     // 宽、高、深
    
    // 获取 AABB 边界
    func getAABB() -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let half = size * 0.5
        return (position - half, position + half)
    }
    
    // OBB 简易相交测试 (带偏航角 Y-Axis Rotation)
    func intersects(other: CyberVolume, selfRotation: Float, otherRotation: Float) -> Bool {
        // 先进行快速 AABB 粗筛
        let (min1, max1) = self.getAABB()
        let (min2, max2) = other.getAABB()
        
        let aabbOverlap = (min1.x <= max2.x && max1.x >= min2.x) &&
                          (min1.y <= max2.y && max1.y >= min2.y) &&
                          (min1.z <= max2.z && max1.z >= min2.z)
        
        if !aabbOverlap { return false }
        if selfRotation == 0 && otherRotation == 0 { return true }
        
        // 针对分离轴定理 (SAT) 的精细 OBB 降维投影简化实现 (主要考虑 XZ 平面旋转)
        let r11 = cos(selfRotation), r12 = sin(selfRotation)
        let r21 = cos(otherRotation), r22 = sin(otherRotation)
        
        // 检查两轴向距离，由于是高密度跑酷，引入核心轴向阻断
        let deltaZ = abs(self.position.z - other.position.z)
        let maxAllowedZ = (self.size.z * abs(r11) + self.size.x * abs(r12) + other.size.z * abs(r21) + other.size.x * abs(r22)) * 0.5
        return deltaZ <= maxAllowedZ
    }
}

enum ObstacleType: CaseIterable {
    case neonSign, holoBarrier, droneSentry, plasmaGate
}

struct BuildingData {
    let id: UUID = UUID()
    var gridPosition: CGPoint // Matrix 坐标
    let height: CGFloat
    let styleColor: UIColor
}

// MARK: - 核心游戏场景

class CyberRunnerScene: SKScene {
    
    // --- 游戏配置常量 ---
    private let laneWidth: CGFloat = 120.0
    private let baseScrollSpeed: CGFloat = 450.0
    private var currentScrollSpeed: CGFloat = 450.0
    
    // --- 纯业务数据状态 ---
    private var playerLane: Int = 1 // 0: 左, 1: 中, 2: 右
    private var playerTargetX: CGFloat = 0.0
    private var playerVelocityX: CGFloat = 0.0
    private let dampingFactor: CGFloat = 0.15 // iPad 物理阻尼系数
    
    private var gameTime: TimeInterval = 0.0
    private var score: Int = 0
    
    // --- 节点缓存 ---
    private var playerNode: SKShapeNode!
    private var matrixContainer: SKNode!
    private var obstacleContainer: SKNode!
    private var hudLabel: SKLabelNode!
    
    // --- 矩阵生成引擎状态 ---
    private var lastGeneratedZ: CGFloat = 0.0
    private var activeBuildings: [BuildingData] = []
    
    // --- 多指触控追踪缓存 ---
    private var activeTouches: [UITouch: CGPoint] = [:]
    
    // MARK: - 场景初始化
    
    override func didMove(to view: SKView) {
        self.backgroundColor = .black
        self.anchorPoint = CGPoint(x: 0.5, y: 0.1) // 拔高视野，营造向下俯视的高楼矩阵感
        
        setupContainers()
        setupPlayer()
        setupHUD()
        triggerMatrixGeneration(initial: true)
    }
    
    private func setupContainers() {
        matrixContainer = SKNode()
        addChild(matrixContainer)
        
        obstacleContainer = SKNode()
        addChild(obstacleContainer)
    }
    
    private func setupPlayer() {
        // 赛博风格三角梭形战机/义体形态代理
        playerNode = SKShapeNode()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 35))
        path.addLine(to: CGPoint(x: -20, y: -25))
        path.addLine(to: CGPoint(x: 20, y: -25))
        path.closeSubpath()
        
        playerNode.path = path
        playerNode.fillColor = .cyan
        playerNode.strokeColor = .white
        playerNode.glowWidth = 8.0
        
        playerTargetX = getXPosition(for: playerLane)
        playerNode.position = CGPoint(x: playerTargetX, y: 0)
        addChild(playerNode)
    }
    
    private func setupHUD() {
        hudLabel = SKLabelNode(fontNamed: "Courier-Bold")
        hudLabel.fontSize = 24
        hudLabel.fontColor = .green
        hudLabel.position = CGPoint(x: 0, y: size.height * 0.75)
        hudLabel.horizontalAlignmentMode = .center
        addChild(hudLabel)
    }
    
    private func getXPosition(for lane: Int) -> CGFloat {
        return CGFloat(lane - 1) * laneWidth
    }
    
    // MARK: - iPad 多指触控物理阻尼变道引擎
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let location = touch.location(in: self)
            activeTouches[touch] = location
        }
        evaluateMultiTouchGestures()
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if let _ = activeTouches[touch] {
                activeTouches[touch] = touch.location(in: self)
            }
        }
        evaluateMultiTouchGestures()
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            activeTouches.removeValue(forKey: touch)
        }
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
    
    private func evaluateMultiTouchGestures() {
        guard !activeTouches.isEmpty else { return }
        
        // 计算所有有效触控点的平均横向偏移量，实现多指协同阻尼拉扯
        let sumX = activeTouches.values.reduce(0.0) { $0 + $1.x }
        let avgX = sumX / CGFloat(activeTouches.count)
        
        // 映射到目标车道线
        if avgX < -laneWidth * 0.5 {
            playerLane = 0
        } else if avgX > laneWidth * 0.5 {
            playerLane = 2
        } else {
            playerLane = 1
        }
        playerTargetX = getXPosition(for: playerLane)
    }
    
    // MARK: - 贝塞尔曲线动态 AI 调度系统 (核心控制中枢)
    
    /// 计算三阶贝塞尔曲线上的点，用于动态拟合难度演进曲线
    private func calculateBezierIntensity(t: Float, p0: Float, p1: Float, p2: Float, p3: Float) -> Float {
        let u = 1.0 - t
        let tt = t * t
        let uu = u * u
        let uuu = uu * u
        let ttt = tt * t
        
        return (uuu * p0) + (3.0 * uu * t * p1) + (3.0 * u * tt * p2) + (ttt * p3)
    }
    
    private func evaluateAIDifficulty(currentTime: TimeInterval) {
        // 将时间周期映射在 0~1 循环或阶梯中
        let period = 60.0 // 每60秒完成一次难度大灌注演进
        let t = Float(currentTime.truncatingRemainder(dividingBy: period) / period)
        
        // 难度特征控制点 (P0:新手, P1:激进飙升, P2:高压折磨, P3:地狱矩阵)
        let p0: Float = 1.0
        let p1: Float = 2.5
        let p2: Float = 4.0
        let p3: Float = 5.5
        
        let difficultyFactor = calculateBezierIntensity(t: t, p0: p0, p1: p1, p2: p2, p3: p3)
        
        // 根据贝塞尔派生因子实时灌注核心业务属性
        currentScrollSpeed = baseScrollSpeed * CGFloat(1.0 + (difficultyFactor * 0.15))
        
        // 动态注入障碍物生成密度
        if arc4random_uniform(100) < UInt32(10 * difficultyFactor) {
            spawnDynamicObstacle(factor: difficultyFactor)
        }
    }
    
    // MARK: - 高密度摩天大楼程序化生成矩阵 (Procedural Generation)
    
    private func triggerMatrixGeneration(initial: Bool) {
        let generationChunk: CGFloat = 300.0
        let startY = initial ? -200.0 : lastGeneratedZ
        let endY = initial ? size.height + 600.0 : lastGeneratedZ + generationChunk
        
        var currentY = startY
        while currentY < endY {
            // 左右两侧双向生成高密度背景矩阵，留空中间赛道
            for col in [-2, -1, 1, 2] {
                if arc4random_uniform(100) > 30 { // 70% 填充率
                    let height = CGFloat.random(in: 120...400)
                    let blockWidth = CGFloat.random(in: 80...140)
                    
                    let building = SKShapeNode(rectOf: CGSize(width: blockWidth, height: height), cornerRadius: 4)
                    building.fillColor = UIColor(red: .random(in: 0.05...0.15),
                                                 green: .random(in: 0.05...0.2),
                                                 blue: .random(in: 0.15...0.35),
                                                 alpha: 1.0)
                    building.strokeColor = UIColor.cyan.withAlphaComponent(0.3)
                    building.lineWidth = 1.5
                    
                    let posX = CGFloat(col) * laneWidth * 1.2 + CGFloat.random(in: -20...20)
                    building.position = CGPoint(x: posX, y: currentY + height * 0.5)
                    
                    // 标记用于物理视差与矩阵剔除
                    building.name = "building"
                    matrixContainer.addChild(building)
                }
            }
            currentY += CGFloat.random(in: 150...250)
        }
        lastGeneratedZ = currentY
    }
    
    // MARK: - 障碍物派发注入
    
    private func spawnDynamicObstacle(factor: Float) {
        // 防止同帧过于频繁无脑刷怪
        guard obstacleContainer.children.count < 12 else { return }
        
        let targetLane = Int.random(in: 0...2)
        let obstacleType = ObstacleType.allCases.randomElement()!
        
        let obsSize: CGSize
        let obsColor: UIColor
        
        switch obstacleType {
        case .neonSign:
            obsSize = CGSize(width: laneWidth * 0.7, height: 40)
            obsColor = .systemPink
        case .holoBarrier:
            obsSize = CGSize(width: laneWidth * 1.1, height: 30)
            obsColor = .orange
        case .droneSentry:
            obsSize = CGSize(width: 40, height: 40)
            obsColor = .red
        case .plasmaGate:
            obsSize = CGSize(width: laneWidth * 0.5, height: 60)
            obsColor = .purple
        }
        
        let obstacleNode = SKShapeNode(rectOf: obsSize, cornerRadius: 2)
        obstacleNode.fillColor = obsColor.withAlphaComponent(0.8)
        obstacleNode.strokeColor = .white
        obstacleNode.lineWidth = 2.0
        obstacleNode.glowWidth = 4.0
        obstacleNode.name = "obstacle"
        
        // 绑定深度特征属性信息到userData用于 3D AABB/OBB 碰撞解码
        obstacleNode.userData = NSMutableDictionary()
        obstacleNode.userData?.setValue(Float(targetLane), forKey: "lane")
        obstacleNode.userData?.setValue(Float(obsSize.width), forKey: "width")
        obstacleNode.userData?.setValue(Float(obsSize.height), forKey: "depth")
        obstacleNode.userData?.setValue(Float.random(in: -0.2...0.2), forKey: "rotation") // 偏航角
        
        obstacleNode.position = CGPoint(x: getXPosition(for: targetLane), y: size.height + 100)
        obstacleContainer.addChild(obstacleNode)
    }
    
    // MARK: - 每帧物理管线刷新与碰撞检测
    
    override func update(_ currentTime: TimeInterval) {
        if gameTime == 0 { gameTime = currentTime }
        let deltaTime = currentTime - gameTime
        gameTime = currentTime
        
        score += Int(currentScrollSpeed * CGFloat(deltaTime) * 0.1)
        hudLabel.text = "AMPLITUDE: \(score) | SPEED: \(Int(currentScrollSpeed))KM/H"
        
        // 1. AI 难度核心指标动态计算注入
        evaluateAIDifficulty(currentTime: currentTime)
        
        // 2. iPad 多指触控物理阻尼平滑跟踪 (基于严密阻尼临界插值)
        let diffX = playerTargetX - playerNode.position.x
        playerVelocityX = diffX * dampingFactor
        playerNode.position.x += playerVelocityX
        
        // 3. 场景整体下移渲染滚动
        let scrollDistance = currentScrollSpeed * CGFloat(deltaTime)
        
        matrixContainer.children.forEach { node in
            node.position.y -= scrollDistance
            if node.position.y < -300 {
                node.removeFromParent()
            }
        }
        
        obstacleContainer.children.forEach { node in
            node.position.y -= scrollDistance
            if node.position.y < -100 {
                node.removeFromParent()
            }
        }
        
        // 4. 连续流矩阵增量追加检测
        if matrixContainer.children.count < 40 {
            triggerMatrixGeneration(initial: false)
        }
        
        // 5. 3D 空间 AABB/OBB 高度混合碰撞检测校验
        performCyberCollisionCheck()
    }
    
    private func performCyberCollisionCheck() {
        // 构建玩家当前的 CyberVolume 模拟三维包围体 (高度归一化)
        let playerVolume = CyberVolume(
            position: SIMD3<Float>(Float(playerLane), 0.0, Float(playerNode.position.x)),
            size: SIMD3<Float>(0.6, 1.0, 40.0)
        )
        
        for obstacle in obstacleContainer.children {
            guard let dict = obstacle.userData as? NSMutableDictionary,
                  let obsLane = dict.value(forKey: "lane") as? Float,
                  let width = dict.value(forKey: "width") as? Float,
                  let depth = dict.value(forKey: "depth") as? Float,
                  let rot = dict.value(forKey: "rotation") as? Float else { continue }
            
            // 构建阻碍物当前帧转换所得的 OBB 实体
            let obstacleVolume = CyberVolume(
                position: SIMD3<Float>(obsLane, 0.0, Float(obstacle.position.x)),
                size: SIMD3<Float>(0.8, 1.0, depth)
            )
            
            // 映射判断 Y 轴 (当前游戏平面的直观跑酷碰撞区)
            let distanceToPlayer = abs(obstacle.position.y - playerNode.position.y)
            if distanceToPlayer < CGFloat(depth * 0.5 + 25.0) {
                // 纵向重合切入，启动高级 3D 空间 OBB 相交测试
                if playerVolume.intersects(other: obstacleVolume, selfRotation: 0.0, otherRotation: rot) {
                    executeGameOverImpact()
                    break
                }
            }
        }
    }
    
    private func executeGameOverImpact() {
        // 发生高维矩阵碰撞崩溃，瞬间触发画面炫目闪烁并重置难度
        let flashAction = SKAction.sequence([
            SKAction.run { self.backgroundColor = .white },
            SKAction.wait(forDuration: 0.05),
            SKAction.run { self.backgroundColor = .black }
        ])
        run(flashAction)
        
        score = max(0, score - 500) // 碰撞惩罚扣分
        obstacleContainer.removeAllChildren() // 清理障碍
    }
}

// MARK: - SwiftUI 托管容器入口 (直接在 iPad 渲染上屏)

public struct CyberGameView: View {
    public init() {}
    
    var scene: SKScene {
        let scene = CyberRunnerScene()
        scene.size = CGSize(width: 768, height: 1024)
        scene.scaleMode = .resizeFill
        return scene
    }
    
    public var body: some View {
        SpriteView(scene: scene)
            .ignoresSafeArea()
            .statusBar(hidden: true)
    }
}
