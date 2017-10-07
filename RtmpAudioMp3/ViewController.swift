//
//  ViewController.swift
//  RtmpAudioMp3
//
//  Created by Soheb Mahmood on 01/07/2017.
//  Copyright © 2017 Soheb Mahmood. All rights reserved.
//

import UIKit
import lf
import AVFoundation

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        
        let conn = RTMPConnection()
        let stream = RTMPStream(connection: conn)
        
        let vidLayer = AVSampleBufferDisplayLayer()
        vidLayer.frame = view.bounds
        view.layer.addSublayer(vidLayer)
        
        
        stream.setSampleBufferLayer(layer: vidLayer);
        
        conn.connect("rtmp://192.168.1.194/real")
        stream.play("test", nil)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }


}

