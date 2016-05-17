import Foundation
import Vapor

#if DEBUG
  private let MaxRepoCount = 50
#else
  private let MaxRepoCount = 1000
#endif

private let MaxConcurrentSlowFetchOperations = 50
private let MaxConcurrentFastFetchOperations = 10
private let RepoTimeoutInterval = NSTimeInterval(60*60*24)

class User {
  private static var reposById = [Int: Repo]()
  private static let reposByIdQueue = dispatch_queue_create("reposById", DISPATCH_QUEUE_CONCURRENT)
  
  private static func cachedRepo(id: Int) -> Repo? {
    var cachedRepo: Repo?
    dispatch_sync(self.reposByIdQueue, { cachedRepo = self.reposById[id] })
    return cachedRepo
  }

  static var cachedRepos: [Repo] {
    get {
      var cachedRepos = [Repo]()
      dispatch_sync(self.reposByIdQueue, { cachedRepos = Array(self.reposById.values) })
      return cachedRepos
    }
  }
  
  private static func cacheRepo(repo: Repo) {
    dispatch_barrier_sync(self.reposByIdQueue, { self.reposById[repo.id] = repo })
  }

  private static let usernameQueue = dispatch_queue_create("username", DISPATCH_QUEUE_CONCURRENT)
  private static let timeStampQueue = dispatch_queue_create("timeStamp", DISPATCH_QUEUE_CONCURRENT)
  private static let reposQueue = dispatch_queue_create("repos", DISPATCH_QUEUE_CONCURRENT)
  private static let reposStateQueue = dispatch_queue_create("reposState", DISPATCH_QUEUE_CONCURRENT)
  private static let fetchedRepoCountsQueue = dispatch_queue_create("fetchedRepoCounts", DISPATCH_QUEUE_CONCURRENT)
  
  static func purgeRepos() {
    dispatch_barrier_sync(self.reposByIdQueue, {
      let now = NSDate()
      
      self.reposById
      .filter { _, repo in return now.timeIntervalSince(repo.timeStamp) > RepoTimeoutInterval }
      .forEach { id, _ in self.reposById.removeValue(forKey: id) }
    })
  }
  
  private static let fetchQueue = dispatch_queue_create("fetch", DISPATCH_QUEUE_CONCURRENT)

  private static let fastFetchOperationQueue: NSOperationQueue = {
    let operationQueue = NSOperationQueue()
    
    operationQueue.maxConcurrentOperationCount = MaxConcurrentFastFetchOperations
    operationQueue.qualityOfService = .userInitiated
    
    return operationQueue
  }()
  
  private static let slowFetchOperationQueue: NSOperationQueue = {
    let operationQueue = NSOperationQueue()

    operationQueue.maxConcurrentOperationCount = MaxConcurrentSlowFetchOperations
    operationQueue.qualityOfService = .utility
    
    return operationQueue
  }()

  enum ReposState {
    case notFetched
    case fetching
    case fetched
  }
  
  private var accessToken: String?
  private var _username = ""
  private var _timeStamp = NSDate()
  private var _repos = [Repo]()
  private var _reposState = ReposState.notFetched
  private var _fetchedRepoCounts = (fetchedCount: 0, totalCount: 0)
  
  private(set) var username: String {
    get { var value: String?; dispatch_sync(User.usernameQueue, { value = self._username }); return value! }
    set { dispatch_barrier_sync(User.usernameQueue, { self._username = newValue }) }
  }
  
  private(set) var timeStamp: NSDate {
    get { var value: NSDate?; dispatch_sync(User.timeStampQueue, { value = self._timeStamp }); return value! }
    set { dispatch_barrier_sync(User.timeStampQueue, { self._timeStamp = newValue }) }
  }
  
  private(set) var repos: [Repo] {
    get { var value: [Repo]?; dispatch_sync(User.reposQueue, { value = self._repos }); return value! }
    set { dispatch_barrier_sync(User.reposQueue, { self._repos = newValue }) }
  }
  
  private(set) var reposState: ReposState {
    get { var value: ReposState?; dispatch_sync(User.reposStateQueue, { value = self._reposState }); return value! }
    set { dispatch_barrier_sync(User.reposStateQueue, { self._reposState = newValue }) }
  }
  
  private(set) var fetchedRepoCounts: (fetchedCount: Int, totalCount: Int) {
    get { var value: (fetchedCount: Int, totalCount: Int)?; dispatch_sync(User.fetchedRepoCountsQueue, { value = self._fetchedRepoCounts }); return value! }
    set { dispatch_barrier_sync(User.fetchedRepoCountsQueue, { self._fetchedRepoCounts = newValue }) }
  }
  
  func initializeWithCode(_ code: String) {
    dispatch_async(User.fetchQueue, {
      if let accessToken = self.exchangeCodeForAccessToken(code: code) {
        self.accessToken = accessToken
        
        self.username = self.fetchUsername() ?? "(unknown)"
        
        self.reposState = .fetching
        self.repos = self.fetchStarredRepos(dicts: self.fetchStarredRepoDicts())
        
        for repo in self.repos {
          User.cacheRepo(repo: repo)
        }
      }
      
      self.reposState = .fetched
    })
  }

  func updateTimeStamp() {
    self.timeStamp = NSDate()
  }
  
  private func exchangeCodeForAccessToken(code: String) -> String? {
    var accessToken: String?
    let requestComponents = NSURLComponents(string: "https://github.com/login/oauth/access_token",
                                            queryDict: [
                                                         "client_id": GitHubClientID,
                                                         "client_secret": GitHubClientSecret,
                                                         "code": code
                                                       ])!
    let operation = NSBlockOperation(block: {
      let (data, _, _) = NSURLSession.shared().synchronousDataTask(with: requestComponents.url!)
      
      if let queryData = data,
             queryString = String(data: queryData, encoding: NSUTF8StringEncoding),
             urlComponents = NSURLComponents(string: "?\(queryString)") {
        accessToken = urlComponents.queryItems?.filter({ $0.name == "access_token" }).first?.value
      }
    })
    
    User.fastFetchOperationQueue.addOperations([operation], waitUntilFinished: true)
    
    return accessToken
  }

  private func fetchUsername() -> String? {
    var username: String?
    let operation = NSBlockOperation(block: {
      let (data, _, _) = NSURLSession.shared().synchronousDataTask(with: NSURL(string: "https://api.github.com/user")!,
                                                                   headers: self.authorizedRequestHeaders())
      
      if let bytes = data?.byteArray, json = try? Json(Data(bytes)), dict: [String: Node] = json.object {
        username = dict["login"]?.string
      }
    })
    
    User.fastFetchOperationQueue.addOperations([operation], waitUntilFinished: true)
    
    return username
  }
  
  private func fetchStarredRepoDicts() -> [[String: Node]] {
    guard let _ = self.accessToken else { return [] }
    
    var dicts = [[String: Node]]()
    var page = 1
    var perPage = 100
    
#if DEBUG
    perPage = 10
#endif
    
    repeat {
      let requestComponents = NSURLComponents(string: "https://api.github.com/user/starred",
                                              queryDict: [
                                                           "page": String(page),
                                                           "per_page": String(perPage)
                                                         ])!
      let operation = NSBlockOperation(block: {
        let (data, _, _) = NSURLSession.shared().synchronousDataTask(with: requestComponents.url!,
                                                                     headers: self.authorizedRequestHeaders(with: ["Accept": "application/vnd.github.star+json"]))
        
        if let bytes = data?.byteArray, json = try? Json(Data(bytes)), array: [Node] = json.array {
          dicts += array.flatMap { $0.object }

          if array.count < perPage || dicts.count >= MaxRepoCount {
            perPage = 0
          }
          else {
            page += 1
          }
        }
        else {
          perPage = 0
        }
      })
      
      User.fastFetchOperationQueue.addOperations([operation], waitUntilFinished:true)
    } while perPage > 0
    
    return dicts
  }
  
  private func fetchStarredRepos(dicts: [[String: Node]]) -> [Repo] {
    guard let _ = self.accessToken else { return [] }

    self.fetchedRepoCounts = (fetchedCount: 0, totalCount: dicts.count)
    
    var cachedRepos = [Repo]()
    var newRepos = [Repo]()
    
    for dict in dicts {
      if let repoDict = dict["repo"]?.object,
             id = repoDict["id"]?.int,
             name = repoDict["name"]?.string,
             ownerDict = repoDict["owner"]?.object,
             ownerId = ownerDict["id"]?.int,
             ownerName = ownerDict["login"]?.string,
             forksCount = repoDict["forks"]?.int,
             starsCount = repoDict["stargazers_count"]?.int,
             starredAtStr = dict["starred_at"]?.string,
             starredAt = NSDate.date(fromIsoString: starredAtStr) {
        if let repo = User.cachedRepo(id: id) {
          cachedRepos.append(repo)
        }
        else {
          newRepos.append(Repo(id: id, name: name, ownerId: ownerId, ownerName: ownerName,
                               forksCount: forksCount, starsCount: starsCount, starredAt: starredAt))
        }
      }
    }

    self.fetchedRepoCounts = (fetchedCount: cachedRepos.count, totalCount: dicts.count)

    let operations = newRepos.map { repo in
      return NSBlockOperation(block: {
        if let readmeUrl = repo.readmeUrl {
          let (data, _, _) = NSURLSession.shared().synchronousDataTask(with: readmeUrl,
                                                                       headers: self.authorizedRequestHeaders(with: ["Accept": "application/vnd.github.raw"]))
          
          if let stringData = data, string = String(data: stringData, encoding: NSUTF8StringEncoding) {
            repo.setReadme(withMarkdown: string)
            self.fetchedRepoCounts = (fetchedCount: (self.fetchedRepoCounts.fetchedCount + 1),
                                      totalCount: self.fetchedRepoCounts.totalCount)
          }
        }
      })
    }
    
    User.slowFetchOperationQueue.addOperations(operations, waitUntilFinished: true)

    return cachedRepos + newRepos
  }
  
  private func authorizedRequestHeaders(with headers: [String:String] = [:]) -> [String:String] {
    guard let accessToken = self.accessToken else { return headers }
    
    var authorizedHeaders = headers
    
    authorizedHeaders["Authorization"] = "token \(accessToken)"
    
    return authorizedHeaders
  }
}
