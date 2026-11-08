import SwiftUI
import Combine
import AudioToolbox
import UIKit

// MARK: - Board constants and geometry

enum Ludo {
    static let names = ["Red", "Green", "Yellow", "Blue"]

    static let colors: [Color] = [
        Color(red: 0.91, green: 0.22, blue: 0.22),
        Color(red: 0.16, green: 0.69, blue: 0.33),
        Color(red: 1.00, green: 0.78, blue: 0.10),
        Color(red: 0.15, green: 0.47, blue: 0.93)
    ]
    static let darkColors: [Color] = [
        Color(red: 0.62, green: 0.09, blue: 0.12),
        Color(red: 0.06, green: 0.40, blue: 0.17),
        Color(red: 0.80, green: 0.54, blue: 0.00),
        Color(red: 0.06, green: 0.25, blue: 0.65)
    ]
    static let lightColors: [Color] = [
        Color(red: 1.00, green: 0.55, blue: 0.50),
        Color(red: 0.55, green: 0.90, blue: 0.60),
        Color(red: 1.00, green: 0.93, blue: 0.50),
        Color(red: 0.55, green: 0.76, blue: 1.00)
    ]

    /// Index on the 52 cell main track where each color enters the board.
    static let startIndex = [0, 13, 26, 39]
    /// Safe cells: the four start cells and the four star cells.
    static let safe: Set<Int> = [0, 13, 26, 39, 8, 21, 34, 47]
    /// Top left corner (column, row) of each 6x6 base.
    static let baseOrigin: [(Int, Int)] = [(0, 0), (9, 0), (9, 9), (0, 9)]

    /// The 52 cell clockwise track as (column, row) on a 15x15 grid.
    static let track: [(Int, Int)] = [
        (1, 6), (2, 6), (3, 6), (4, 6), (5, 6),
        (6, 5), (6, 4), (6, 3), (6, 2), (6, 1), (6, 0),
        (7, 0), (8, 0),
        (8, 1), (8, 2), (8, 3), (8, 4), (8, 5),
        (9, 6), (10, 6), (11, 6), (12, 6), (13, 6), (14, 6),
        (14, 7), (14, 8),
        (13, 8), (12, 8), (11, 8), (10, 8), (9, 8),
        (8, 9), (8, 10), (8, 11), (8, 12), (8, 13), (8, 14),
        (7, 14), (6, 14),
        (6, 13), (6, 12), (6, 11), (6, 10), (6, 9),
        (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8),
        (0, 7), (0, 6)
    ]

    /// The five coloured home column cells of each player.
    static let homeColumn: [[(Int, Int)]] = [
        [(1, 7), (2, 7), (3, 7), (4, 7), (5, 7)],
        [(7, 1), (7, 2), (7, 3), (7, 4), (7, 5)],
        [(13, 7), (12, 7), (11, 7), (10, 7), (9, 7)],
        [(7, 13), (7, 12), (7, 11), (7, 10), (7, 9)]
    ]

    /// Token progress: -1 base, 0...50 main track, 51...55 home column, 56 finished.
    static func globalIndex(_ player: Int, _ pos: Int) -> Int {
        (startIndex[player] + pos) % 52
    }

    /// Centre of a token in grid units (cell centre = column + 0.5).
    static func point(player p: Int, pos: Int, token i: Int) -> CGPoint {
        if pos < 0 {
            let o = baseOrigin[p]
            let dx: CGFloat = (i % 2 == 0) ? 2 : 4
            let dy: CGFloat = (i / 2 == 0) ? 2 : 4
            return CGPoint(x: CGFloat(o.0) + dx, y: CGFloat(o.1) + dy)
        }
        if pos <= 50 {
            let t = track[(startIndex[p] + pos) % 52]
            return CGPoint(x: CGFloat(t.0) + 0.5, y: CGFloat(t.1) + 0.5)
        }
        if pos <= 55 {
            let t = homeColumn[p][pos - 51]
            return CGPoint(x: CGFloat(t.0) + 0.5, y: CGFloat(t.1) + 0.5)
        }
        let off = (CGFloat(i) - 1.5) * 0.22
        switch p {
        case 0: return CGPoint(x: 6.85, y: 7.5 + off)
        case 1: return CGPoint(x: 7.5 + off, y: 6.85)
        case 2: return CGPoint(x: 8.15, y: 7.5 + off)
        default: return CGPoint(x: 7.5 + off, y: 8.15)
        }
    }
}

struct TokenID: Identifiable, Hashable {
    let player: Int
    let index: Int
    var id: Int { player * 4 + index }
}

// MARK: - Game engine

@MainActor
final class GameViewModel: ObservableObject {
    enum Phase { case idle, rolling, choosing, moving, over }
    enum Seat: String, CaseIterable {
        case off = "Off"
        case human = "Human"
        case cpu = "CPU"
    }

    @Published var seats: [Seat] = [.human, .cpu, .cpu, .cpu]
    @Published var positions: [[Int]] = Array(repeating: Array(repeating: -1, count: 4), count: 4)
    @Published var current = 0
    @Published var dice = 1
    @Published var diceSpin = 0.0
    @Published var phase: Phase = .idle
    @Published var movable: Set<Int> = []
    @Published var message = "Ready"
    @Published var ranking: [Int] = []
    @Published var movingToken: TokenID?

    @Published var soundOn: Bool = UserDefaults.standard.object(forKey: "ludo.sound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundOn, forKey: "ludo.sound") }
    }
    @Published var hapticsOn: Bool = UserDefaults.standard.object(forKey: "ludo.haptics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticsOn, forKey: "ludo.haptics") }
    }

    private var session = 0
    private var sixes = 0

    var canRoll: Bool { phase == .idle && seats[current] == .human }

    func displayName(_ p: Int) -> String {
        Ludo.names[p] + (seats[p] == .cpu ? " (CPU)" : "")
    }

    // MARK: Feedback helpers

    private func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        if hapticsOn { UIImpactFeedbackGenerator(style: style).impactOccurred() }
    }
    private func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        if hapticsOn { UINotificationFeedbackGenerator().notificationOccurred(type) }
    }
    private func sfx(_ id: SystemSoundID) {
        if soundOn { AudioServicesPlaySystemSound(id) }
    }
    private func wait(_ seconds: Double, _ s: Int) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return s == session && !Task.isCancelled
    }

    // MARK: Game flow

    func startGame() {
        session += 1
        positions = Array(repeating: Array(repeating: -1, count: 4), count: 4)
        ranking = []
        sixes = 0
        movable = []
        movingToken = nil
        dice = 1
        current = seats.firstIndex(where: { $0 != .off }) ?? 0
        beginTurn()
    }

    func exitGame() {
        session += 1
        phase = .idle
        movable = []
        movingToken = nil
    }

    private func beginTurn() {
        phase = .idle
        movable = []
        if seats[current] == .cpu {
            message = "\(Ludo.names[current]) is thinking"
            let s = session
            Task {
                guard await wait(0.9, s) else { return }
                performRoll()
            }
        } else {
            message = "\(Ludo.names[current]), roll the dice"
        }
    }

    private func nextPlayer() {
        sixes = 0
        var n = current
        for _ in 0..<4 {
            n = (n + 1) % 4
            if seats[n] != .off && !ranking.contains(n) { break }
        }
        current = n
        beginTurn()
    }

    func humanRoll() {
        guard canRoll else { return }
        performRoll()
    }

    private func performRoll() {
        guard phase == .idle else { return }
        phase = .rolling
        let s = session
        tap(.medium)
        sfx(1104)
        Task {
            for _ in 0..<8 {
                dice = Int.random(in: 1...6)
                diceSpin += 90
                guard await wait(0.075, s) else { return }
            }
            let value = Int.random(in: 1...6)
            dice = value
            resolveRoll(value, s)
        }
    }

    private func resolveRoll(_ v: Int, _ s: Int) {
        sixes = (v == 6) ? sixes + 1 : 0
        if sixes == 3 {
            sixes = 0
            message = "Three sixes in a row! Turn lost"
            notify(.error)
            Task {
                guard await wait(1.3, s) else { return }
                nextPlayer()
            }
            return
        }

        let all = moveOptions(for: current, roll: v)
        if all.isEmpty {
            message = "No moves for \(Ludo.names[current])"
            Task {
                guard await wait(1.0, s) else { return }
                nextPlayer()
            }
            return
        }

        var seen = Set<Int>()
        for i in all { seen.insert(positions[current][i]) }
        if seen.count == 1 {
            let choice = all[0]
            Task {
                guard await wait(0.35, s) else { return }
                await perform(choice, s)
            }
            return
        }

        movable = Set(all)
        phase = .choosing
        if seats[current] == .cpu {
            message = "\(Ludo.names[current]) is choosing"
            Task {
                guard await wait(0.8, s) else { return }
                await perform(cpuChoose(all), s)
            }
        } else {
            message = "Tap a glowing token to move"
        }
    }

    private func moveOptions(for p: Int, roll: Int) -> [Int] {
        var result: [Int] = []
        for i in 0..<4 {
            let pos = positions[p][i]
            if pos == -1 {
                if roll == 6 { result.append(i) }
            } else if pos < 56 && pos + roll <= 56 {
                result.append(i)
            }
        }
        return result
    }

    func tapToken(_ t: TokenID) {
        guard phase == .choosing, t.player == current, seats[current] == .human, movable.contains(t.index) else { return }
        let s = session
        Task { await perform(t.index, s) }
    }

    private func perform(_ i: Int, _ s: Int) async {
        guard s == session else { return }
        let p = current
        let r = dice
        phase = .moving
        movable = []
        movingToken = TokenID(player: p, index: i)

        if positions[p][i] == -1 {
            message = "\(Ludo.names[p]) enters the board"
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { positions[p][i] = 0 }
            sfx(1104)
            tap(.medium)
            guard await wait(0.5, s) else { return }
        } else {
            message = "\(Ludo.names[p]) moves \(r)"
            for _ in 0..<r {
                withAnimation(.easeInOut(duration: 0.15)) { positions[p][i] += 1 }
                sfx(1103)
                tap(.light)
                guard await wait(0.18, s) else { return }
            }
        }

        let pos = positions[p][i]
        var captured = 0
        if (0...50).contains(pos) {
            let g = Ludo.globalIndex(p, pos)
            if !Ludo.safe.contains(g) {
                for q in 0..<4 where q != p && seats[q] != .off {
                    for j in 0..<4 {
                        let qp = positions[q][j]
                        if (0...50).contains(qp) && Ludo.globalIndex(q, qp) == g {
                            captured += 1
                            withAnimation(.easeInOut(duration: 0.5)) { positions[q][j] = -1 }
                        }
                    }
                }
            }
        }

        var bonus = (r == 6)
        if captured > 0 {
            bonus = true
            message = "\(Ludo.names[p]) captured a token!"
            notify(.warning)
            sfx(1057)
            guard await wait(0.7, s) else { return }
        }
        if pos == 56 {
            bonus = true
            message = "A \(Ludo.names[p]) token reached home!"
            notify(.success)
            guard await wait(0.6, s) else { return }
        }
        movingToken = nil

        if positions[p].allSatisfy({ $0 == 56 }) {
            ranking.append(p)
            let left = (0..<4).filter { seats[$0] != .off && !ranking.contains($0) }
            if left.count <= 1 {
                if let last = left.first { ranking.append(last) }
                phase = .over
                message = "Game over"
                notify(.success)
                sfx(1025)
                return
            }
            message = "\(Ludo.names[p]) finished in place \(ranking.count)!"
            guard await wait(1.1, s) else { return }
            nextPlayer()
            return
        }

        if bonus {
            message = "\(Ludo.names[p]) gets another turn!"
            guard await wait(0.5, s) else { return }
            beginTurn()
        } else {
            nextPlayer()
        }
    }

    // MARK: CPU brain

    private func isThreatened(cell g: Int, for p: Int) -> Bool {
        if Ludo.safe.contains(g) { return false }
        for q in 0..<4 where q != p && seats[q] != .off {
            for j in 0..<4 {
                let qp = positions[q][j]
                if (0...50).contains(qp) {
                    let d = (g - Ludo.globalIndex(q, qp) + 52) % 52
                    if (1...6).contains(d) { return true }
                }
            }
        }
        return false
    }

    private func cpuChoose(_ options: [Int]) -> Int {
        let p = current
        let r = dice
        var best = options[0]
        var bestScore = -Double.infinity

        for i in options {
            let pos = positions[p][i]
            let np = (pos == -1) ? 0 : pos + r
            var score = Double(np) * 0.6

            if np == 56 { score += 100 }
            if pos == -1 { score += 55 }
            if (51...55).contains(np) { score += 25 }

            if (0...50).contains(np) {
                let g = Ludo.globalIndex(p, np)
                if Ludo.safe.contains(g) {
                    score += 18
                } else {
                    for q in 0..<4 where q != p && seats[q] != .off {
                        for j in 0..<4 {
                            let qp = positions[q][j]
                            if (0...50).contains(qp) && Ludo.globalIndex(q, qp) == g {
                                score += 70 + Double(qp)
                            }
                        }
                    }
                    if isThreatened(cell: g, for: p) { score -= 30 }
                }
            }

            if (0...50).contains(pos) {
                let g = Ludo.globalIndex(p, pos)
                if isThreatened(cell: g, for: p) { score += 22 }
            }

            score += Double.random(in: 0...4)
            if score > bestScore {
                bestScore = score
                best = i
            }
        }
        return best
    }
}

// MARK: - Feedback helper for views

enum Haptic {
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}

// MARK: - Root

struct RootView: View {
    @StateObject private var vm = GameViewModel()
    @State private var inGame = false

    var body: some View {
        ZStack {
            if inGame {
                GameView(vm: vm) {
                    withAnimation(.easeInOut(duration: 0.35)) { inGame = false }
                }
                .transition(.move(edge: .trailing))
            } else {
                MenuView(vm: vm) {
                    vm.startGame()
                    withAnimation(.easeInOut(duration: 0.35)) { inGame = true }
                }
                .transition(.move(edge: .leading))
            }
        }
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.08, blue: 0.25),
                    Color(red: 0.25, green: 0.10, blue: 0.45),
                    Color(red: 0.08, green: 0.10, blue: 0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle().fill(Ludo.colors[0].opacity(0.20)).frame(width: 300, height: 300).blur(radius: 70).offset(x: -150, y: -300)
            Circle().fill(Ludo.colors[3].opacity(0.20)).frame(width: 300, height: 300).blur(radius: 70).offset(x: 160, y: 320)
            Circle().fill(Ludo.colors[2].opacity(0.12)).frame(width: 260, height: 260).blur(radius: 70).offset(x: 160, y: -250)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Menu

struct MenuView: View {
    @ObservedObject var vm: GameViewModel
    var onStart: () -> Void
    @State private var showRules = false
    @State private var bob = false

    private var playerCount: Int { vm.seats.filter { $0 != .off }.count }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    logo
                    seatCard
                    playButton
                    settingsCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .sheet(isPresented: $showRules) { RulesView() }
        .onAppear { bob = true }
    }

    private var logo: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { i in
                    Text(["L", "U", "D", "O"][i])
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .foregroundStyle(i == 2 ? Color.black.opacity(0.75) : Color.white)
                        .frame(width: 66, height: 66)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(LinearGradient(colors: [Ludo.colors[i], Ludo.darkColors[i]], startPoint: .top, endPoint: .bottom))
                        )
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.8), lineWidth: 2))
                        .shadow(color: Ludo.colors[i].opacity(0.55), radius: 10, y: 6)
                        .rotationEffect(.degrees(i % 2 == 0 ? -6 : 6))
                        .offset(y: bob ? -5 : 5)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: bob)
                }
            }
            Text("The classic board game")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.75))
        }
        .padding(.top, 20)
    }

    private var seatCard: some View {
        VStack(spacing: 14) {
            Text("Choose players")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(0..<4, id: \.self) { p in
                SeatRow(vm: vm, player: p)
            }
            if playerCount < 2 {
                Text("Pick at least 2 players to start")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private var playButton: some View {
        Button {
            Haptic.tap()
            onStart()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                Text("PLAY")
            }
            .font(.system(size: 24, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                LinearGradient(colors: [Color(red: 0.25, green: 0.80, blue: 0.40), Color(red: 0.08, green: 0.50, blue: 0.28)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 20)
            )
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.6), lineWidth: 2))
            .shadow(color: Color.green.opacity(0.45), radius: 14, y: 6)
        }
        .disabled(playerCount < 2)
        .opacity(playerCount < 2 ? 0.45 : 1)
    }

    private var settingsCard: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $vm.soundOn) {
                Label("Sound effects", systemImage: "speaker.wave.2.fill")
            }
            Toggle(isOn: $vm.hapticsOn) {
                Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
            }
            Button {
                showRules = true
            } label: {
                Label("How to play", systemImage: "questionmark.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .tint(Color.green)
        .font(.system(size: 16, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
}

struct SeatRow: View {
    @ObservedObject var vm: GameViewModel
    let player: Int

    var body: some View {
        HStack(spacing: 12) {
            TokenView(player: player, size: 34, movable: false)
                .frame(width: 38, height: 38)
            Text(Ludo.names[player])
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            HStack(spacing: 0) {
                ForEach(GameViewModel.Seat.allCases, id: \.self) { s in
                    Button {
                        vm.seats[player] = s
                        Haptic.select()
                    } label: {
                        Text(s.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(vm.seats[player] == s ? (player == 2 ? Color.black.opacity(0.8) : Color.white) : Color.white.opacity(0.6))
                            .frame(width: 56, height: 32)
                            .background(Capsule().fill(vm.seats[player] == s ? Ludo.colors[player] : Color.clear))
                    }
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.10)))
        }
    }
}

struct RulesView: View {
    @Environment(\.dismiss) private var dismiss

    private let rules: [(String, String)] = [
        ("Leave the base", "Roll a 6 to bring a token onto the board."),
        ("Move around", "Tokens travel clockwise by the number you roll."),
        ("Extra turns", "Rolling a 6, capturing an opponent, or bringing a token home gives you another turn."),
        ("Three sixes", "Three sixes in a row lose your turn."),
        ("Capture", "Land on an opponent token to send it back to its base."),
        ("Safe cells", "Coloured start cells and star cells are safe. No captures there."),
        ("Go home", "After one lap, turn into your coloured home column. You need the exact number to reach the centre."),
        ("Win", "Bring all 4 tokens home. The game continues until only one player is left.")
    ]

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 16) {
                Text("How to play")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 24)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(rules.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rules[i].0)
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                    .foregroundStyle(Ludo.colors[i % 4])
                                Text(rules[i].1)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.9))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
                        }
                    }
                    .padding(.horizontal, 20)
                }
                Button {
                    dismiss()
                } label: {
                    Text("Got it")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Ludo.colors[3]))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Game screen

struct GameView: View {
    @ObservedObject var vm: GameViewModel
    var onExit: () -> Void
    @State private var showMenu = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 12) {
                topBar
                playerStrip
                BoardView(vm: vm)
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
                controls
            }
            .padding(.bottom, 6)

            if vm.phase == .over {
                WinnerOverlay(vm: vm, onMenu: onExit)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: vm.phase == .over)
        .confirmationDialog("Game menu", isPresented: $showMenu, titleVisibility: .visible) {
            Button("Resume") {}
            Button("Restart game") { vm.startGame() }
            Button("Main menu", role: .destructive) {
                vm.exitGame()
                onExit()
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var topBar: some View {
        HStack {
            Button { showMenu = true } label: { roundIcon("line.3.horizontal") }
            Spacer()
            Text("LUDO")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: Ludo.colors[vm.current].opacity(0.9), radius: 8)
            Spacer()
            Button { vm.soundOn.toggle() } label: {
                roundIcon(vm.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func roundIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color.white.opacity(0.14)))
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
    }

    private var playerStrip: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { p in
                if vm.seats[p] != .off {
                    PlayerChip(vm: vm, player: p)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            DiceView(value: vm.dice, accent: Ludo.colors[vm.current], size: 84)
                .rotation3DEffect(.degrees(vm.diceSpin), axis: (x: 1, y: 1, z: 0))
                .scaleEffect(vm.phase == .rolling ? 1.12 : 1)
                .animation(.easeInOut(duration: 0.08), value: vm.diceSpin)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: vm.phase)
                .onTapGesture { vm.humanRoll() }

            VStack(alignment: .leading, spacing: 10) {
                Text(vm.message)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)

                Button {
                    vm.humanRoll()
                } label: {
                    Text(vm.canRoll ? "ROLL DICE" : "PLEASE WAIT")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(vm.current == 2 ? Color.black.opacity(0.8) : Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(colors: [Ludo.colors[vm.current], Ludo.darkColors[vm.current]], startPoint: .top, endPoint: .bottom),
                            in: Capsule()
                        )
                        .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
                        .scaleEffect(vm.canRoll && pulse ? 1.04 : 1)
                }
                .disabled(!vm.canRoll)
                .opacity(vm.canRoll ? 1 : 0.5)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Ludo.colors[vm.current].opacity(0.9), lineWidth: 2))
        .padding(.horizontal, 12)
    }
}

struct PlayerChip: View {
    @ObservedObject var vm: GameViewModel
    let player: Int

    var body: some View {
        let isTurn = vm.current == player && vm.phase != .over
        let done = vm.positions[player].filter { $0 == 56 }.count
        let rank = vm.ranking.firstIndex(of: player)
        let subtitle = rank != nil ? "Place \(rank! + 1)" : "Home \(done)/4"

        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: vm.seats[player] == .cpu ? "cpu" : "person.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(Ludo.names[player])
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
            }
            Text(subtitle)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .opacity(0.9)
        }
        .foregroundStyle(player == 2 ? Color.black.opacity(0.8) : Color.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14).fill(Ludo.colors[player].opacity(isTurn ? 1 : 0.35)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white, lineWidth: isTurn ? 2.5 : 0))
        .scaleEffect(isTurn ? 1.06 : 1)
        .shadow(color: isTurn ? Ludo.colors[player].opacity(0.8) : Color.clear, radius: 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isTurn)
    }
}

// MARK: - Dice

struct DiceView: View {
    let value: Int
    let accent: Color
    var size: CGFloat = 80

    private static let layout: [Int: [Int]] = [
        1: [4], 2: [0, 8], 3: [0, 4, 8], 4: [0, 2, 6, 8], 5: [0, 2, 4, 6, 8], 6: [0, 2, 3, 5, 6, 8]
    ]

    var body: some View {
        let dots = Self.layout[value] ?? [4]
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(LinearGradient(colors: [Color.white, Color(white: 0.84)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.22)
                .stroke(accent, lineWidth: 3)
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { c in
                            Circle()
                                .fill(dots.contains(r * 3 + c) ? Color(white: 0.10) : Color.clear)
                                .padding(size * 0.045)
                        }
                    }
                }
            }
            .padding(size * 0.12)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.35), radius: 6, y: 4)
    }
}

// MARK: - Board

struct BoardCanvas: View {
    var body: some View {
        Canvas { ctx, size in
            let c = size.width / 15
            func cellRect(_ col: Int, _ row: Int) -> CGRect {
                CGRect(x: CGFloat(col) * c, y: CGFloat(row) * c, width: c, height: c)
            }
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * c, y: y * c)
            }
            let gridLine = GraphicsContext.Shading.color(Color.black.opacity(0.22))

            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))

            // Bases
            for p in 0..<4 {
                let o = Ludo.baseOrigin[p]
                let outer = CGRect(x: CGFloat(o.0) * c, y: CGFloat(o.1) * c, width: 6 * c, height: 6 * c)
                ctx.fill(
                    Path(outer),
                    with: .linearGradient(
                        Gradient(colors: [Ludo.colors[p], Ludo.darkColors[p]]),
                        startPoint: CGPoint(x: outer.minX, y: outer.minY),
                        endPoint: CGPoint(x: outer.maxX, y: outer.maxY)
                    )
                )
                let inner = outer.insetBy(dx: c, dy: c)
                ctx.fill(Path(roundedRect: inner, cornerRadius: c * 0.6), with: .color(.white))
                for k in 0..<4 {
                    let sp = Ludo.point(player: p, pos: -1, token: k)
                    let r = c * 0.62
                    let rect = CGRect(x: sp.x * c - r, y: sp.y * c - r, width: 2 * r, height: 2 * r)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Ludo.lightColors[p].opacity(0.85)))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(Ludo.colors[p]), lineWidth: c * 0.08)
                }
            }

            // Main track
            for (idx, t) in Ludo.track.enumerated() {
                let r = cellRect(t.0, t.1)
                let startOwner = Ludo.startIndex.firstIndex(of: idx)
                let fill: Color = startOwner != nil ? Ludo.colors[startOwner!] : Color.white
                ctx.fill(Path(r), with: .color(fill))
                ctx.stroke(Path(r), with: gridLine, lineWidth: 0.6)
                if Ludo.safe.contains(idx) {
                    let starColor: Color = startOwner != nil ? Color.white.opacity(0.9) : Color.gray.opacity(0.75)
                    ctx.draw(
                        Text("★").font(.system(size: c * 0.66)).foregroundColor(starColor),
                        at: CGPoint(x: r.midX, y: r.midY)
                    )
                }
            }

            // Home columns
            for p in 0..<4 {
                for t in Ludo.homeColumn[p] {
                    let r = cellRect(t.0, t.1)
                    ctx.fill(Path(r), with: .color(Ludo.colors[p]))
                    ctx.stroke(Path(r), with: gridLine, lineWidth: 0.6)
                }
            }

            // Centre triangles
            let corners: [(CGPoint, CGPoint)] = [
                (pt(6, 6), pt(6, 9)),
                (pt(6, 6), pt(9, 6)),
                (pt(9, 6), pt(9, 9)),
                (pt(6, 9), pt(9, 9))
            ]
            for p in 0..<4 {
                var path = Path()
                path.move(to: corners[p].0)
                path.addLine(to: corners[p].1)
                path.addLine(to: pt(7.5, 7.5))
                path.closeSubpath()
                ctx.fill(path, with: .color(Ludo.colors[p]))
                ctx.stroke(path, with: .color(Color.white.opacity(0.9)), lineWidth: 1)
            }
        }
    }
}

struct TokenView: View {
    let player: Int
    let size: CGFloat
    let movable: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.30))
                .frame(width: size, height: size)
                .offset(y: size * 0.09)
                .blur(radius: size * 0.05)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Ludo.lightColors[player], Ludo.colors[player], Ludo.darkColors[player]],
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 0,
                        endRadius: size * 0.75
                    )
                )
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Color.white, lineWidth: max(1.5, size * 0.09)))
            Circle()
                .fill(Color.white.opacity(0.45))
                .frame(width: size * 0.28, height: size * 0.28)
                .offset(x: -size * 0.16, y: -size * 0.18)
            if movable {
                Circle()
                    .stroke(Color.white, lineWidth: 2.5)
                    .frame(width: size, height: size)
                    .scaleEffect(pulse ? 1.45 : 1.0)
                    .opacity(pulse ? 0.1 : 0.95)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(movable ? (pulse ? 1.12 : 0.96) : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct BoardView: View {
    @ObservedObject var vm: GameViewModel

    private var tokens: [TokenID] {
        var list: [TokenID] = []
        for p in 0..<4 where vm.seats[p] != .off {
            for i in 0..<4 { list.append(TokenID(player: p, index: i)) }
        }
        return list
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cell = side / 15
            let all = tokens
            ZStack(alignment: .topLeading) {
                BoardCanvas()
                    .frame(width: side, height: side)
                ForEach(all) { t in
                    let place = placement(for: t, in: all)
                    let isMovable = vm.phase == .choosing && t.player == vm.current && vm.movable.contains(t.index)
                    TokenView(player: t.player, size: cell * 0.8 * place.scale, movable: isMovable)
                        .position(x: place.point.x * cell, y: place.point.y * cell)
                        .zIndex(vm.movingToken == t ? 100.0 : (isMovable ? 50.0 : 1.0))
                        .onTapGesture { vm.tapToken(t) }
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.9), lineWidth: 3))
        .shadow(color: Color.black.opacity(0.5), radius: 14, y: 8)
    }

    private func placement(for t: TokenID, in all: [TokenID]) -> (point: CGPoint, scale: CGFloat) {
        let pos = vm.positions[t.player][t.index]
        let base = Ludo.point(player: t.player, pos: pos, token: t.index)
        if pos < 0 { return (base, 1) }
        if pos == 56 { return (base, 0.5) }

        let mates = all.filter { o in
            let op = vm.positions[o.player][o.index]
            return op >= 0 && op < 56 && Ludo.point(player: o.player, pos: op, token: o.index) == base
        }
        let n = mates.count
        if n <= 1 { return (base, 1) }

        let k = mates.firstIndex(of: t) ?? 0
        let spots: [CGPoint]
        let s: CGFloat
        if n == 2 {
            spots = [CGPoint(x: -0.2, y: 0), CGPoint(x: 0.2, y: 0)]
            s = 0.78
        } else if n == 3 {
            spots = [CGPoint(x: -0.2, y: -0.18), CGPoint(x: 0.2, y: -0.18), CGPoint(x: 0, y: 0.2)]
            s = 0.68
        } else {
            spots = [CGPoint(x: -0.2, y: -0.2), CGPoint(x: 0.2, y: -0.2), CGPoint(x: -0.2, y: 0.2), CGPoint(x: 0.2, y: 0.2)]
            s = 0.6
        }
        let o = spots[k % spots.count]
        return (CGPoint(x: base.x + o.x, y: base.y + o.y), s)
    }
}

// MARK: - Winner screen

struct WinnerOverlay: View {
    @ObservedObject var vm: GameViewModel
    var onMenu: () -> Void

    private let medals = ["🥇", "🥈", "🥉", "4th"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            ConfettiView()
            VStack(spacing: 16) {
                Text("🏆").font(.system(size: 70))
                Text("\(Ludo.names[vm.ranking.first ?? 0]) wins!")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                VStack(spacing: 8) {
                    ForEach(Array(vm.ranking.enumerated()), id: \.offset) { idx, p in
                        HStack(spacing: 10) {
                            Text(medals[min(idx, 3)])
                                .font(.system(size: 22))
                                .frame(width: 44)
                            TokenView(player: p, size: 26, movable: false)
                                .frame(width: 30, height: 30)
                            Text(vm.displayName(p))
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.10)))
                    }
                }

                Button {
                    Haptic.tap()
                    vm.startGame()
                } label: {
                    Text("Play again")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color(red: 0.16, green: 0.69, blue: 0.33)))
                }
                Button {
                    vm.exitGame()
                    onMenu()
                } label: {
                    Text("Main menu")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color(red: 0.12, green: 0.10, blue: 0.30)))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.25), lineWidth: 1.5))
            .padding(.horizontal, 28)
        }
    }
}

struct ConfettiView: View {
    struct Piece: Identifiable {
        let id = UUID()
        let x = CGFloat.random(in: 0...1)
        let size = CGFloat.random(in: 6...12)
        let delay = Double.random(in: 0...2)
        let duration = Double.random(in: 2.5...4.5)
        let rotation = Double.random(in: 0...360)
        let color: Color = Ludo.colors.randomElement() ?? Color.white
    }

    @State private var pieces: [Piece] = (0..<50).map { _ in Piece() }
    @State private var fall = false

    var body: some View {
        GeometryReader { geo in
            ForEach(pieces) { p in
                Rectangle()
                    .fill(p.color)
                    .frame(width: p.size, height: p.size * 1.6)
                    .rotationEffect(.degrees(fall ? p.rotation + 540 : p.rotation))
                    .position(x: p.x * geo.size.width, y: fall ? geo.size.height + 40 : -40)
                    .animation(.linear(duration: p.duration).delay(p.delay).repeatForever(autoreverses: false), value: fall)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { fall = true }
    }
}
