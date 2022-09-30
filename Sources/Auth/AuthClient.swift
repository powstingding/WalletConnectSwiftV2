import Foundation
import Combine
import WalletConnectUtils
import WalletConnectPairing
import WalletConnectRelay

/// WalletConnect Auth Client
///
/// Cannot be instantiated outside of the SDK
///
/// Access via `Auth.instance`
public class AuthClient {
    enum Errors: Error {
        case unknownWalletAddress
    }

    // MARK: - Public Properties

    /// Publisher that sends authentication requests
    ///
    /// Wallet should subscribe on events in order to receive auth requests.
    public var authRequestPublisher: AnyPublisher<AuthRequest, Never> {
        authRequestPublisherSubject.eraseToAnyPublisher()
    }

    /// Publisher that sends authentication responses
    ///
    /// App should subscribe for events in order to receive CACAO object with a signature matching authentication request.
    ///
    /// Emited result may be an error.
    public var authResponsePublisher: AnyPublisher<(id: RPCID, result: Result<Cacao, AuthError>), Never> {
        authResponsePublisherSubject.eraseToAnyPublisher()
    }



    /// Publisher that sends web socket connection status
    public let socketConnectionStatusPublisher: AnyPublisher<SocketConnectionStatus, Never>

    /// An object that loggs SDK's errors and info messages
    public let logger: ConsoleLogging

    // MARK: - Private Properties

    private let pairingClient: PairingClient

    private var authResponsePublisherSubject = PassthroughSubject<(id: RPCID, result: Result<Cacao, AuthError>), Never>()
    private var authRequestPublisherSubject = PassthroughSubject<AuthRequest, Never>()
    private let appRequestService: AppRequestService
    private let appRespondSubscriber: AppRespondSubscriber
    private let walletRequestSubscriber: WalletRequestSubscriber
    private let walletRespondService: WalletRespondService
    private let pendingRequestsProvider: PendingRequestsProvider
    private var account: Account?

    init(appRequestService: AppRequestService,
         appRespondSubscriber: AppRespondSubscriber,
         walletRequestSubscriber: WalletRequestSubscriber,
         walletRespondService: WalletRespondService,
         account: Account?,
         pendingRequestsProvider: PendingRequestsProvider,
         logger: ConsoleLogging,
         socketConnectionStatusPublisher: AnyPublisher<SocketConnectionStatus, Never>,
         pairingClient: PairingClient
    ) {
        self.appRequestService = appRequestService
        self.walletRequestSubscriber = walletRequestSubscriber
        self.walletRespondService = walletRespondService
        self.appRespondSubscriber = appRespondSubscriber
        self.account = account
        self.pendingRequestsProvider = pendingRequestsProvider
        self.logger = logger
        self.socketConnectionStatusPublisher = socketConnectionStatusPublisher
        self.pairingClient = pairingClient
        setUpPublishers()
    }

    /// For wallet to establish a pairing and receive an authentication request
    /// Wallet should call this function in order to accept peer's pairing proposal and be able to subscribe for future authentication request.
    /// - Parameter uri: Pairing URI that is commonly presented as a QR code by a dapp or delivered with universal linking.
    ///
    /// Throws Error:
    /// - When URI is invalid format or missing params
    /// - When topic is already in use
    @available(*, deprecated, message: "Use Pair.pair(uri:) instead")
    public func pair(uri: WalletConnectURI) async throws {
        try await pairingClient.pair(uri: uri)
    }

    /// For a dapp to send an authentication request to a wallet
    /// - Parameter params: Set of parameters required to request authentication
    ///
    /// - Returns: Pairing URI that should be shared with wallet out of bound. Common way is to present it as a QR code.
    public func request(_ params: RequestParams) async throws -> WalletConnectURI {
        logger.debug("Requesting Authentication")
        let uri = try await pairingClient.create()
        try await appRequestService.request(params: params, topic: uri.topic)
        return uri
    }

    /// For a dapp to send an authentication request to a wallet
    /// - Parameter params: Set of parameters required to request authentication
    /// - Parameter topic: Pairing topic that wallet already subscribes for
    public func request(_ params: RequestParams, topic: String) async throws {
        logger.debug("Requesting Authentication on existing pairing")
        try pairingClient.getPairing(for: topic)
        try await appRequestService.request(params: params, topic: topic)
    }

    /// For a wallet to respond on authentication request
    /// - Parameters:
    ///   - requestId: authentication request id
    ///   - signature: CACAO signature of requested message
    public func respond(requestId: RPCID, signature: CacaoSignature) async throws {
        guard let account = account else { throw Errors.unknownWalletAddress }
        try await walletRespondService.respond(requestId: requestId, signature: signature, account: account)
    }

    /// For wallet to reject authentication request
    /// - Parameter requestId: authentication request id
    public func reject(requestId: RPCID) async throws {
        try await walletRespondService.respondError(requestId: requestId)
    }

    @available(*, deprecated, message: "Use Pair.disconnect(topic:) instead")
    public func disconnect(topic: String) async throws {
        try await pairingClient.disconnect(topic: topic)
    }

    @available(*, deprecated, message: "Use Pair.ping(topic:) instead")
    public func ping(topic: String) async throws {
        try await pairingClient.ping(topic: topic)
    }

    @available(*, deprecated, message: "Use Pair.getPairings() instead")
    public func getPairings() -> [Pairing] {
        pairingClient.getPairings()
    }

    /// Query pending authentication requests
    /// - Returns: Pending authentication requests
    public func getPendingRequests() throws -> [AuthRequest] {
        guard let account = account else { throw Errors.unknownWalletAddress }
        return try pendingRequestsProvider.getPendingRequests(account: account)
    }

    private func setUpPublishers() {
        appRespondSubscriber.onResponse = { [unowned self] (id, result) in
            authResponsePublisherSubject.send((id, result))
        }

        walletRequestSubscriber.onRequest = { [unowned self] request in
            authRequestPublisherSubject.send(request)
        }
    }
}
