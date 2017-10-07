import Foundation
import AudioToolbox
import AVFoundation

typealias Byte = UInt8

struct AtomicBoolean {

    private var val: Byte = 0

    /// Sets the value, and returns the previous value.
    /// The test/set is an atomic operation.
    mutating func testAndSet(value: Bool) -> Bool {
        if value {
            return OSAtomicTestAndSet(0, &val)
        } else {
            return OSAtomicTestAndClear(0, &val)
        }
    }

    /// Returns the current value of the boolean.
    /// The value may change before this method returns.
    func test() -> Bool {
        return val != 0
    }

}

class AudioStreamPlayback {
    static let defaultBufferSize:UInt32 = 128 * 1024
    static let defaultNumberOfBuffers:Int = 128
    static let defaultMaxPacketDescriptions:Int = 1

    var await:Bool = false
    var config:AudioSpecificConfig?
    var runloop:CFRunLoop? = nil
    var numberOfBuffers:Int = AudioStreamPlayback.defaultNumberOfBuffers
    var maxPacketDescriptions:Int = AudioStreamPlayback.defaultMaxPacketDescriptions

    var soundTransform:SoundTransform = SoundTransform() {
        didSet {
            guard let queue:AudioQueueRef = queue, running else {
                return
            }
            soundTransform.setParameter(queue)
        }
    }

    fileprivate(set) var running:Bool = false
    var formatDescription:AudioStreamBasicDescription? = nil
    var fileTypeHint:AudioFileTypeID? = nil {
        didSet {
//            logger.info("File Type Hint: \(fileTypeHint) - \(oldValue)")
            guard let fileTypeHint:AudioFileTypeID = fileTypeHint, fileTypeHint != oldValue else {
//                logger.info("Values are the same, skipping")
                return
            }
//            logger.info("File types are not the same, resetting")
            var fileStreamID:OpaquePointer? = nil
            let status = AudioFileStreamOpen(
                    unsafeBitCast(self, to: UnsafeMutableRawPointer.self),
                    propertyListenerProc,
                    packetsProc,
                    fileTypeHint,
                    &fileStreamID)
            if status == noErr {
                //logger.info("Setting new fileStreamID")
                self.fileStreamID = fileStreamID
            } else {
                AudioStreamPlayback.printOSStatus(status)
            }
        }
    }
    let lockQueue:DispatchQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.AudioStreamPlayback.lock")
    fileprivate var bufferSize:UInt32 = AudioStreamPlayback.defaultBufferSize
    fileprivate var queue:AudioQueueRef? = nil {
        didSet {
//            logger.info("Queue: Old value: \(oldValue) - New Queue: \(queue)")
            guard let oldValue:AudioQueueRef = oldValue else {
                return
            }
            var status = AudioQueueStop(oldValue, true)
            if (status != noErr) {
                AudioStreamPlayback.printOSStatus(status)
            }
            status = AudioQueueDispose(oldValue, true)
            if (status != noErr) {
                AudioStreamPlayback.printOSStatus(status)
            }

        }
    }
    fileprivate var inuse:[AtomicBoolean] = []
    fileprivate var buffers:[AudioQueueBufferRef] = []
    fileprivate var current:Int = 0
    fileprivate var started:Bool = false
    fileprivate var filledBytes:UInt32 = 0
    fileprivate var packetDescriptions:[AudioStreamPacketDescription] = []
    fileprivate var fileStreamID:AudioFileStreamID? = nil {
        didSet {
            guard let oldValue:AudioFileStreamID = oldValue else {
                return
            }
            let status = AudioFileStreamClose(oldValue)
            if (status != noErr) {
                AudioStreamPlayback.printOSStatus(status)
            }
        }
    }
    fileprivate var isPacketDescriptionsFull:Bool {
        return packetDescriptions.count == maxPacketDescriptions
    }

    fileprivate var outputCallback:AudioQueueOutputCallback = {(
        inUserData: UnsafeMutableRawPointer?,
        inAQ: AudioQueueRef,
        inBuffer:AudioQueueBufferRef) -> Void in
//        logger.info("Getting output callback fo dat MP3")
        let playback:AudioStreamPlayback = unsafeBitCast(inUserData, to: AudioStreamPlayback.self)
        playback.onOutputForQueue(inAQ, inBuffer)
    }

    fileprivate var packetsProc:AudioFileStream_PacketsProc = {(
        inClientData:UnsafeMutableRawPointer,
        inNumberBytes:UInt32,
        inNumberPackets:UInt32,
        inInputData:UnsafeRawPointer,
        inPacketDescriptions:UnsafeMutablePointer<AudioStreamPacketDescription>) -> Void in
//        logger.info("On PacketsProc - # of Bytes:\(inNumberBytes)" +
//                "\n# of Packets: \(inNumberPackets)" +
//                "\nInClientData: \(inClientData)" +
//                "\nInInputData: \(inInputData)")
        let playback:AudioStreamPlayback = unsafeBitCast(inClientData, to: AudioStreamPlayback.self)
        playback.initializeForAudioQueue()
        playback.onAudioPacketsForFileStream(inNumberBytes, inNumberPackets, inInputData, inPacketDescriptions)
    }

    fileprivate var propertyListenerProc:AudioFileStream_PropertyListenerProc = {(
        inClientData:UnsafeMutableRawPointer,
        inAudioFileStream:AudioFileStreamID,
        inPropertyID:AudioFileStreamPropertyID,
        ioFlags:UnsafeMutablePointer<AudioFileStreamPropertyFlags>) -> Void in
//        logger.info("On PropertyListenerProc")
        let playback:AudioStreamPlayback = unsafeBitCast(inClientData, to: AudioStreamPlayback.self)
        playback.onPropertyChangeForFileStream(inAudioFileStream, inPropertyID, ioFlags)
    }

    func parseBytes(_ data:Data) {
        //logger.info("Running? \(running)\nfileStreamID: \(fileStreamID) - self.fileStreamId: \(self.fileStreamID)")

        guard let fileStreamID:AudioFileStreamID = fileStreamID, running else {
//            logger.warning("FileStreamId is null :/")
            return
        }

        data.withUnsafeBytes { (bytes:UnsafePointer<UInt8>) -> Void in
//            logger.info("parseBytes fileStreamID: \(fileStreamID)\ncount: \(data.count)\ndata \(data.hexEncodedString())")
            let osData = AudioFileStreamParseBytes(
                fileStreamID,
                UInt32(data.count),
                bytes,
                //AudioFileStreamParseFlags(rawValue: 0)
                    AudioFileStreamParseFlags.discontinuity
            )
            if (osData == noErr) {
                //logger.info("Buffering is apparently fine")
            } else {
//                logger.error("Error'd! Returned back \(osData) from \(data.hexEncodedString())")
            }
        }
    }

    func isBufferFull(_ packetSize:UInt32) -> Bool {
        return (bufferSize - filledBytes) < packetSize
    }

    func appendBuffer(_ inInputData:UnsafeRawPointer, inPacketDescription:inout AudioStreamPacketDescription) {
        // is current buffer in use - log & return if true
        let bufferInUse: Bool = inuse[current].testAndSet(value: true)
        if (bufferInUse){
//            logger.info("Buffer is in use, bailing!")
            return
        }

        // v dead code
        let offset:Int = Int(inPacketDescription.mStartOffset)
        let packetSize:UInt32 = inPacketDescription.mDataByteSize
//        let bufferFull = isBufferFull(packetSize)
//        logger.info("Offset: \(offset)\nPacket Size: \(packetSize)\nIs Buffer Full? \(bufferFull)\nPacket Description Full: \(isPacketDescriptionsFull)")
//
//        if (bufferFull || isPacketDescriptionsFull) {
//            enqueueBuffer()
//            rotateBuffer()
//        }
        // v good bit
//        logger.info("We survived the bufferpocalypse")
        var isRunning = OSStatus()
        var converterError = OSStatus()
        var varSize = UInt32(MemoryLayout<OSStatus>.size)
        if (queue != nil) {
            AudioQueueGetProperty(queue!, kAudioQueueProperty_IsRunning, &isRunning, &varSize)
            AudioQueueGetProperty(queue!, kAudioQueueProperty_ConverterError, &converterError, &varSize)
//            logger.info("Is running? \(isRunning)\nConverter errors? \(converterError)")
        }
        let buffer:AudioQueueBufferRef = buffers[current]
        memcpy(buffer.pointee.mAudioData.advanced(by: Int(filledBytes)), inInputData.advanced(by: offset), Int(packetSize))
        inPacketDescription.mStartOffset = Int64(filledBytes)
        packetDescriptions.append(inPacketDescription)
        filledBytes += packetSize
        // unconditional enqueue & rotate - rotate does not check lock

        enqueueBuffer()
        rotateBuffer()
    }

    func rotateBuffer() {
        current += 1
        if (numberOfBuffers <= current) {
            current = 0
        }
        filledBytes = 0
        packetDescriptions.removeAll()
    }

    func enqueueBuffer() {
        guard let queue:AudioQueueRef = queue, running else {
            return
        }
//        logger.info("Filled buffer \(current)")
        let buffer:AudioQueueBufferRef = buffers[current]
        buffer.pointee.mAudioDataByteSize = filledBytes
//        logger.info("Enqueue buffer with \(filledBytes) bytes")
        let enqueueBuffer = AudioQueueEnqueueBuffer(
                queue,
                buffer,
                UInt32(packetDescriptions.count),
                &packetDescriptions)
        guard enqueueBuffer == noErr else {
            AudioStreamPlayback.printOSStatus(enqueueBuffer)
            logger.warning("AudioQueueEnqueueBuffer")
            return
        }
    }

    func startQueueIfNeed() {
        guard let queue:AudioQueueRef = queue, !started else {
            logger.error("Starting queue failed\nQueue: \(self.queue)\nStarted? \(self.started)")
            return
        }
//        logger.info("Starting queue")
        started = true
        AudioQueuePrime(queue, 0, nil)
        AudioQueueStart(queue, nil)
    }

    func initializeForAudioQueue() {
        guard let _:AudioStreamBasicDescription = formatDescription, self.queue == nil else {
            return
        }
        var queue:AudioQueueRef? = nil
//        logger.info("Format description: \(formatDescription)")
        DispatchQueue.global(qos: .background).sync {
            self.runloop = CFRunLoopGetCurrent()
            let status = AudioQueueNewOutput(
                &self.formatDescription!,
                self.outputCallback,
                unsafeBitCast(self, to: UnsafeMutableRawPointer.self),
                nil,
                nil,
                0,
                &queue)

            if (status != noErr) {
                AudioStreamPlayback.printOSStatus(status)
                logger.warning("Failed in AudioQueueNewOutput")
            }
        }
//        if let cookie:[UInt8] = getMagicCookieForFileStream() {
//            let _:Bool = setMagicCookieForQueue(cookie)
//        }
        soundTransform.setParameter(queue!)
        for _ in 0..<numberOfBuffers {
            var buffer:AudioQueueBufferRef? = nil
            AudioQueueAllocateBuffer(queue!, bufferSize, &buffer)
            if let buffer:AudioQueueBufferRef = buffer {
                buffers.append(buffer)
            }
        }
        self.queue = queue
        startQueueIfNeed()
    }

    final func onOutputForQueue(_ inAQ: AudioQueueRef, _ inBuffer:AudioQueueBufferRef) {
//        logger.info("Outputting buffer contents - getting index of \(inBuffer)")
        guard let i:Int = buffers.index(of: inBuffer) else {
            logger.error("Failed to get buffer")
            return
        }
//        logger.info("Freeing buffer \(i)")
        inuse[i].testAndSet(value: false)
//        logger.info("Freed buffer \(i)")
    }

    final func onAudioPacketsForFileStream(_ inNumberBytes:UInt32, _ inNumberPackets:UInt32, _ inInputData:UnsafeRawPointer, _ inPacketDescriptions:UnsafeMutablePointer<AudioStreamPacketDescription>) {
//        logger.info("Appending \(inNumberPackets) to buffer")
        for i in 0..<Int(inNumberPackets) {
            appendBuffer(inInputData, inPacketDescription: &inPacketDescriptions[i])
        }
    }

    final func onPropertyChangeForFileStream(_ inAudioFileStream:AudioFileStreamID, _ inPropertyID:AudioFileStreamPropertyID, _ ioFlags:UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
        switch inPropertyID {
        case kAudioFileStreamProperty_ReadyToProducePackets:
//            logger.info("Ready to produce packets")
            break
        case kAudioFileStreamProperty_DataFormat:
//            logger.info("Getting format description")
            formatDescription = getFormatDescriptionForFileStream()
        default:
            logger.info("Default")
            break
        }
    }

    func setMagicCookieForQueue(_ inData: [UInt8]) -> Bool {
        guard let queue:AudioQueueRef = queue else {
            return false
        }
        var status:OSStatus = noErr
        status = AudioQueueSetProperty(queue, kAudioQueueProperty_MagicCookie, inData, UInt32(inData.count))
        guard status == noErr else {
            AudioStreamPlayback.printOSStatus(status)
            logger.warning("status \(status)")
            return false
        }
        return true
    }

    func getFormatDescriptionForFileStream() -> AudioStreamBasicDescription? {
        guard let fileStreamID:AudioFileStreamID = fileStreamID else {
            return nil
        }
        var data:AudioStreamBasicDescription = AudioStreamBasicDescription()
        var size:UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status: OSStatus = AudioFileStreamGetProperty(fileStreamID, kAudioFileStreamProperty_DataFormat, &size, &data);
        guard status == noErr else {
            AudioStreamPlayback.printOSStatus(status)
            logger.warning("kAudioFileStreamProperty_DataFormat")
            return nil
        }
        return data
    }

    public static func printOSStatus(_ status: OSStatus) {
        logger.warning("Error: \(status)")
        switch (status) {
        case kAudioFileStreamError_UnsupportedFileType:
            logger.warning("Unsupported file type")
        case kAudioFileStreamError_UnsupportedDataFormat:
            logger.warning("Unsupported data format")
        case kAudioFileStreamError_UnsupportedProperty:
            logger.warning("Unsupported property")
        case kAudioFileStreamError_BadPropertySize:
            logger.warning("Bad property size")
        case kAudioFileStreamError_NotOptimized:
            logger.warning("Not optimised")
        case kAudioFileStreamError_InvalidPacketOffset:
            logger.warning("Invalid packet offset")
        case kAudioFileStreamError_InvalidFile:
            logger.warning("Invalid file")
        case kAudioFileStreamError_ValueUnknown:
            logger.warning("Value unknown")
        case kAudioFileStreamError_DataUnavailable:
            logger.warning("Data unavailable")
        case kAudioFileStreamError_IllegalOperation:
            logger.warning("Illegal operation")
        case kAudioFileStreamError_UnspecifiedError:
            logger.warning("Unspecified error")
        case kAudioFileStreamError_DiscontinuityCantRecover:
            logger.warning("Cannot recover from disconuity")
        default:
            logger.warning("Unsure")
        }
    }

    func getMagicCookieForFileStream() -> [UInt8]? {
        guard let fileStreamID:AudioFileStreamID = fileStreamID else {
            return nil
        }
        var size:UInt32 = 0
        var writable:DarwinBoolean = true
        let status1 = AudioFileStreamGetPropertyInfo(fileStreamID, kAudioFileStreamProperty_MagicCookieData, &size, &writable)
        guard status1 == noErr else {
            AudioStreamPlayback.printOSStatus(status1)

            logger.warning("info kAudioFileStreamProperty_MagicCookieData")
            return nil
        }

        var data:[UInt8] = [UInt8](repeating: 0, count: Int(size))
        let status2 = AudioFileStreamGetProperty(fileStreamID, kAudioFileStreamProperty_MagicCookieData, &size, &data)
        guard status2 == noErr else {
            AudioStreamPlayback.printOSStatus(status2)

            logger.warning("kAudioFileStreamProperty_MagicCookieData")
            return nil
        }
        return data
    }
}

extension AudioStreamPlayback: Runnable {
    // MARK: Runnable
    func startRunning() {
        lockQueue.async {
            guard !self.running else {
                return
            }
            //self.inuse = [AtomicBoolean](count: self.numberOfBuffers)
            self.inuse = [AtomicBoolean]()
            for i in 0...self.numberOfBuffers {
                self.inuse.insert(AtomicBoolean.init(), at: i)
            }
            self.started = false
            self.current = 0
            self.filledBytes = 0
            self.fileTypeHint = nil
            self.packetDescriptions.removeAll()
            self.running = true
            AudioUtil.startRunning()
        }
    }

    func stopRunning() {
        lockQueue.async {
            guard self.running else {
                return
            }
            self.queue = nil
            if let runloop:CFRunLoop = self.runloop {
                CFRunLoopStop(runloop)
            }
            self.runloop = nil
            self.inuse.removeAll()
            self.buffers.removeAll()
            self.started = false
            self.fileStreamID = nil
            self.packetDescriptions.removeAll()
            self.running = false
            AudioUtil.stopRunning()
        }
    }
}
