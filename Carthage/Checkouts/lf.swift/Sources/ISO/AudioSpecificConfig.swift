import Foundation
import AVFoundation

/**
 The Audio Specific Config is the global header for MPEG-4 Audio
 
 - seealse:
  - http://wiki.multimedia.cx/index.php?title=MPEG-4_Audio#Audio_Specific_Config
  - http://wiki.multimedia.cx/?title=Understanding_AAC
 */
struct AudioSpecificConfig {
    static let ADTSHeaderSize:Int = 7

    var frequency:SamplingFrequency
    var sampleSize:UInt8
    var channel:ChannelConfiguration
    var frameLengthFlag:Bool = false

    var bytes:[UInt8] {
        var bytes:[UInt8] = [UInt8](repeating: 0, count: 1)
        bytes[0] = 0b00100000 | frequency.rawValue << 2 | sampleSize | (channel == ChannelConfiguration.mono ? 0 : 1)
        return bytes
    }

    init?(bytes:[UInt8]) {
//        logger.info("ASC init: \(bytes.map { String(format: "%02hhx", $0)}.joined())")
//        logger.info("Values - byte0: \(bytes[0]) (in hex: \(String(format: "%02hhx", bytes[0])))")
//        logger.info("Freq: \((bytes[0] >> 2) & 0b00011) Sample size: \((bytes[0] >> 1) & 0b0001) Channel: \(bytes[0] & 0b00000001)")
        guard let
            frequency:SamplingFrequency = SamplingFrequency(rawValue: (bytes[0] >> 2) & 0b00011),
            let sampleSize:UInt8 = ((bytes[0] >> 1) & 0b0001),
            let channel:ChannelConfiguration = ChannelConfiguration(rawValue: bytes[0] & 0b00000001) else {
            return nil
        }
        self.sampleSize = sampleSize
        self.frequency = frequency
        self.channel = channel
    }

    init(frequency:SamplingFrequency, channel:ChannelConfiguration, sampleSize: UInt8) {
        self.frequency = frequency
        self.channel = channel
        self.sampleSize = sampleSize;
    }

    init(formatDescription: CMFormatDescription) {
        let asbd:AudioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)!.pointee
        frequency = SamplingFrequency(sampleRate: asbd.mSampleRate)
        channel = ChannelConfiguration(rawValue: UInt8(asbd.mChannelsPerFrame))!
        sampleSize = 0
    }

    func createAudioStreamBasicDescription() -> AudioStreamBasicDescription {
        var asbd:AudioStreamBasicDescription = AudioStreamBasicDescription()
        asbd.mSampleRate = frequency.sampleRate
        asbd.mFormatID = kAudioFormatMPEGLayer3
        asbd.mFormatFlags = 0
        asbd.mBytesPerPacket = 0
        asbd.mFramesPerPacket = 0
        asbd.mBytesPerFrame = 0
        asbd.mChannelsPerFrame = channel == ChannelConfiguration.mono ? 1 : 2
        asbd.mBitsPerChannel = 0
        asbd.mReserved = 0
        return asbd
    }
}

extension AudioSpecificConfig: CustomStringConvertible {
    // MARK: CustomStringConvertible
    var description:String {
        return Mirror(reflecting: self).description
    }
}

// MARK: -
enum SamplingFrequency: UInt8 {
    case hz96000 = 0
    case hz11025 = 1
    case hz64000 = 2
    case hz44100 = 3
    case hz48000 = 4
    case hz32000 = 5
    case hz24000 = 6
    case hz22050 = 7
    case hz16000 = 8
    case hz12000 = 9
    //case hz11025 = 10
    case hz88200 = 10
    case hz8000  = 11
    case hz7350  = 12

    var sampleRate:Float64 {
        switch self {
        case .hz96000:
            return 96000
        case .hz88200:
            return 88200
        case .hz64000:
            return 64000
        case .hz48000:
            return 48000
        case .hz44100:
            return 44100
        case .hz32000:
            return 32000
        case .hz24000:
            return 24000
        case .hz22050:
            return 22050
        case .hz16000:
            return 16000
        case .hz12000:
            return 12000
        case .hz11025:
            return 11025
        case .hz8000:
            return 8000
        case .hz7350:
            return 7350
        }
    }

    init(sampleRate:Float64) {
        switch Int(sampleRate) {
        case 96000:
            self = .hz96000
        case 88200:
            self = .hz88200
        case 64000:
            self = .hz64000
        case 48000:
            self = .hz48000
        case 44100:
            self = .hz44100
        case 32000:
            self = .hz32000
        case 24000:
            self = .hz24000
        case 22050:
            self = .hz22050
        case 16000:
            self = .hz16000
        case 12000:
            self = .hz12000
        case 11025:
            self = .hz11025
        case 8000:
            self = .hz8000
        case 7350:
            self = .hz7350
        default:
            self = .hz44100
        }
    }
}

// MARK: -
enum ChannelConfiguration: UInt8 {
    case mono = 0
    case stereo = 1
}
