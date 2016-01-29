// The MIT License (MIT)
//
// Copyright (c) 2015 Alexander Grebenyuk (github.com/kean).

import Foundation

// MARK: - ImageLoading

/** Performs loading of images for the image tasks.
*/
public protocol ImageLoading: class {
    /** Managers that controls image loading.
     */
    weak var manager: ImageLoadingManager? { get set }
    
    /** Resumes loading for the given task.
     */
    func resumeLoadingFor(task: ImageTask)
    
    /** Suspends loading for the given task.
     */
    func suspendLoadingFor(task: ImageTask)
    
    /** Cancels loading for the given task.
     */
    func cancelLoadingFor(task: ImageTask)
    
    /** Compares requests for equivalence with regard to caching output image. This method is used for memory caching, in most cases there is no need for filtering out the dynamic part of the request (is there is any).
     */
    func isCacheEquivalent(lhs: ImageRequest, to rhs: ImageRequest) -> Bool
    
    /** Invalidates the receiver.
     */
    func invalidate()
    
    /** Clears the receiver's cache storage (if any).
     */
    func removeAllCachedImages()
}

// MARK: - ImageLoadingDelegate

/** Manages image loading.
*/
public protocol ImageLoadingManager: class {
    /** Sent periodically to notify delegate of task progress.
     */
    func loader(loader: ImageLoading, task: ImageTask, didUpdateProgress progress: ImageTaskProgress)
    
    /** Send when loading for task is completed.
     */
    func loader(loader: ImageLoading, task: ImageTask, didCompleteWithImage image: Image?, error: ErrorType?, userInfo: Any?)
}

// MARK: - ImageLoaderConfiguration

public struct ImageLoaderConfiguration {
    public var dataLoader: ImageDataLoading
    public var decoder: ImageDecoding
    
    /** Image decoding queue. Default queue has a maximum concurrent operation count 1.
     */
    public var decodingQueue = NSOperationQueue(maxConcurrentOperationCount: 1)
    
    /** Image processing queue. Default queue has a maximum concurrent operation count 2.
     */
    public var processingQueue = NSOperationQueue(maxConcurrentOperationCount: 2)
    
    /**
     Initializes configuration with data loader and image decoder.
     
     - parameter dataLoader: Image data loader.
     - parameter decoder: Image decoder. Default `ImageDecoder` instance is created if the parameter is omitted.
     */
    public init(dataLoader: ImageDataLoading, decoder: ImageDecoding = ImageDecoder()) {
        self.dataLoader = dataLoader
        self.decoder = decoder
    }
}

// MARK: - ImageLoaderDelegate

/** Image loader customization endpoints.
*/
public protocol ImageLoaderDelegate {
    /** Compares requests for equivalence with regard to loading image data. Requests should be considered equivalent if data loader can handle both requests with a single session task.
     */
    func loader(loader: ImageLoader, isLoadEquivalent lhs: ImageRequest, to rhs: ImageRequest) -> Bool
    
    /** Compares requests for equivalence with regard to caching output image. This method is used for memory caching, in most cases there is no need for filtering out the dynamic part of the request (is there is any).
     */
    func loader(loader: ImageLoader, isCacheEquivalent lhs: ImageRequest, to rhs: ImageRequest) -> Bool
    
    /** Returns processor for the given request and image.
     *     */
    func loader(loader: ImageLoader, processorForRequest: ImageRequest, image: Image) -> ImageProcessing?
}

public extension ImageLoaderDelegate {
    /** Compares request `URL`, `cachePolicy`, `timeoutInterval`, `networkServiceType` and `allowsCellularAccess`.
     */
    public func loader(loader: ImageLoader, isLoadEquivalent lhs: ImageRequest, to rhs: ImageRequest) -> Bool {
        let a = lhs.URLRequest, b = rhs.URLRequest
        return a.URL == b.URL &&
            a.cachePolicy == b.cachePolicy &&
            a.timeoutInterval == b.timeoutInterval &&
            a.networkServiceType == b.networkServiceType &&
            a.allowsCellularAccess == b.allowsCellularAccess
    }
    
    /** Compares request `URLs`, decompression parameters (`shouldDecompressImage`, `targetSize` and `contentMode`) and processors.
     */
    func loader(loader: ImageLoader, isCacheEquivalent lhs: ImageRequest, to rhs: ImageRequest) -> Bool {
        guard lhs.URLRequest.URL == rhs.URLRequest.URL else {
            return false
        }
        return lhs.shouldDecompressImage == rhs.shouldDecompressImage &&
            lhs.targetSize == rhs.targetSize &&
            lhs.contentMode == rhs.contentMode &&
            isEquivalent(lhs.processor, rhs: rhs.processor)
    }
    
    /** Returns processor with combined image decompressor constructed based on request's target size and content mode, and image processor provided in image request.
     */
    public func loader(loader: ImageLoader, processorForRequest request: ImageRequest, image: Image) -> ImageProcessing? {
        var processors = [ImageProcessing]()
        if request.shouldDecompressImage, let decompressor = self.decompressorFor(request) {
            processors.append(decompressor)
        }
        if let processor = request.processor {
            processors.append(processor)
        }
        return processors.isEmpty ? nil : ImageProcessorComposition(processors: processors)
    }
    
    private func decompressorFor(request: ImageRequest) -> ImageProcessing? {
        #if os(OSX)
            return nil
        #else
            return ImageDecompressor(targetSize: request.targetSize, contentMode: request.contentMode)
        #endif
    }
    
    private func isEquivalent(lhs: ImageProcessing?, rhs: ImageProcessing?) -> Bool {
        switch (lhs, rhs) {
        case let (l?, r?): return l.isEquivalent(r)
        case (nil, nil): return true
        default: return false
        }
    }
}

public class ImageLoaderDefaultDelegate: ImageLoaderDelegate {
    public init() {}
}

// MARK: - ImageLoader

/**
Performs loading of images for the image tasks using objects conforming to `ImageDataLoading`, `ImageDecoding` and `ImageProcessing` protocols. Works in conjunction with the `ImageManager`.

- Provides a transparent loading, decoding and processing with a single completion signal
- Reuses data tasks for equivalent image tasks
*/
public class ImageLoader: ImageLoading {
    public weak var manager: ImageLoadingManager?
    public let configuration: ImageLoaderConfiguration
    
    /** Delegate that the receiver was initialized with. Image loader holds a strong reference to its delegate!
     */
    public let delegate: ImageLoaderDelegate
    
    private var dataLoader: ImageDataLoading {
        return self.configuration.dataLoader
    }
    private var executingTasks = [ImageTask : ImageLoadState]()
    private var dataTasks = [ImageRequestKey : ImageDataTask]()
    private let queue = dispatch_queue_create("ImageLoader.SerialQueue", DISPATCH_QUEUE_SERIAL)
    
    /**
     Initializes image loader with a configuration and a delegate.
     
     - parameter delegate: Instance of `ImageLoaderDefaultDelegate` created if the parameter is omitted. Image loader holds a strong reference to its delegate!
     */
    public init(configuration: ImageLoaderConfiguration, delegate: ImageLoaderDelegate = ImageLoaderDefaultDelegate()) {
        self.configuration = configuration
        self.delegate = delegate
    }
    
    public func resumeLoadingFor(task: ImageTask) {
        dispatch_async(self.queue) {
            let key = ImageRequestKey(task.request, owner: self)
            var dataTask: ImageDataTask! = self.dataTasks[key]
            if dataTask == nil {
                dataTask = self.dataTaskWith(task.request, key: key)
                self.dataTasks[key] = dataTask
            } else {
                self.manager?.loader(self, task: task, didUpdateProgress: dataTask.progress)
            }
            self.executingTasks[task] = ImageLoadState.Loading(dataTask)
            dataTask.resume(task)
        }
    }
    
    private func dataTaskWith(request: ImageRequest, key: ImageRequestKey) -> ImageDataTask {
        let dataTask = ImageDataTask(key: key)
        dataTask.URLSessionTask = self.dataLoader.taskWith(request, progress: { [weak self] completed, total in
            self?.dataTask(dataTask, didUpdateProgress: ImageTaskProgress(completed: completed, total: total))
        }, completion: { [weak self] data, response, error in
            self?.dataTask(dataTask, didCompleteWithData: data, response: response, error: error)
        })
        return dataTask
    }
    
    private func dataTask(dataTask: ImageDataTask, didUpdateProgress progress: ImageTaskProgress) {
        dispatch_async(self.queue) {
            dataTask.progress = progress
            for task in dataTask.tasks {
                self.manager?.loader(self, task: task, didUpdateProgress: dataTask.progress)
            }
        }
    }
    
    private func dataTask(dataTask: ImageDataTask, didCompleteWithData data: NSData?, response: NSURLResponse?, error: ErrorType?) {
        guard let data = data where error == nil else {
            self.dataTask(dataTask, didCompleteWithImage: nil, error: error)
            return;
        }
        self.configuration.decodingQueue.addOperationWithBlock { [weak self] in
            let image = self?.configuration.decoder.decode(data)
            self?.dataTask(dataTask, didCompleteWithImage: image, error: error)
        }
    }
    
    private func dataTask(dataTask: ImageDataTask, didCompleteWithImage image: Image?, error: ErrorType?) {
        dispatch_async(self.queue) {
            for task in dataTask.tasks {
                self.process(image, error: error, forTask: task)
            }
            dataTask.complete()
            self.remove(dataTask)
        }
    }
    
    private func process(image: Image?, error: ErrorType?, forTask task: ImageTask) {
        if let image = image, processor = self.delegate.loader(self, processorForRequest:task.request, image: image) {
            let operation = NSBlockOperation { [weak self] in
                self?.complete(task, image: processor.process(image), error: error)
            }
            self.configuration.processingQueue.addOperation(operation)
            self.executingTasks[task] = ImageLoadState.Processing(operation)
        } else {
            self.complete(task, image: image, error: error)
        }
    }
    
    private func complete(task: ImageTask, image: Image?, error: ErrorType?) {
        dispatch_async(self.queue) {
            self.manager?.loader(self, task: task, didCompleteWithImage: image, error: error, userInfo: nil)
            self.executingTasks[task] = nil
        }
    }
    
    public func suspendLoadingFor(task: ImageTask) {
        dispatch_async(self.queue) {
            if let state = self.executingTasks[task] {
                switch state {
                case .Loading(let sessionTask):
                    sessionTask.suspend(task)
                default: break
                }
            }
        }
    }
    
    public func cancelLoadingFor(task: ImageTask) {
        dispatch_async(self.queue) {
            if let state = self.executingTasks[task] {
                switch state {
                case .Loading(let sessionTask):
                    if sessionTask.cancel(task) {
                        self.remove(sessionTask)
                    }
                case .Processing(let operation):
                    operation.cancel()
                }
                self.executingTasks[task] = nil
            }
        }
    }
    
    private func remove(task: ImageDataTask) {
        if self.dataTasks[task.key] === task {
            self.dataTasks[task.key] = nil
        }
    }
    
    // MARK: Misc
    
    public func isCacheEquivalent(lhs: ImageRequest, to rhs: ImageRequest) -> Bool {
        return self.delegate.loader(self, isCacheEquivalent: lhs, to: rhs)
    }
    
    public func invalidate() {
        self.dataLoader.invalidate()
    }
    
    public func removeAllCachedImages() {
        self.dataLoader.removeAllCachedImages()
    }
}

// MARK: ImageLoader: ImageRequestKeyOwner

extension ImageLoader: ImageRequestKeyOwner {
    public func isEqual(lhs: ImageRequestKey, to rhs: ImageRequestKey) -> Bool {
        return self.delegate.loader(self, isLoadEquivalent: lhs.request, to: rhs.request)
    }
}

// MARK: - ImageLoadState

private enum ImageLoadState {
    case Loading(ImageDataTask)
    case Processing(NSOperation)
}

// MARK: - ImageDataTask

private class ImageDataTask {
    let key: ImageRequestKey
    var URLSessionTask: NSURLSessionTask?
    var executingTasks = Set<ImageTask>()
    var suspendedTasks = Set<ImageTask>()
    var tasks: Set<ImageTask> {
        return self.executingTasks.union(self.suspendedTasks)
    }
    var progress: ImageTaskProgress = ImageTaskProgress()
    
    init(key: ImageRequestKey) {
        self.key = key
    }
    
    func resume(task: ImageTask) {
        self.suspendedTasks.remove(task)
        self.executingTasks.insert(task)
        self.URLSessionTask?.resume()
    }
    
    func cancel(task: ImageTask) -> Bool {
        self.executingTasks.remove(task)
        self.suspendedTasks.remove(task)
        if self.tasks.isEmpty {
            self.URLSessionTask?.cancel()
            self.URLSessionTask = nil
            return true
        }
        return false
    }
    
    func suspend(task: ImageTask) {
        self.executingTasks.remove(task)
        self.suspendedTasks.insert(task)
        if self.executingTasks.isEmpty {
            self.URLSessionTask?.suspend()
        }
    }
    
    func complete() {
        self.executingTasks.removeAll()
        self.suspendedTasks.removeAll()
        self.URLSessionTask = nil
    }
}
