//
//  MaskRCNNConfig.swift
//  WinterVacationProject
//
//  Created by Darko on 2019/2/1.
//  Copyright © 2019 Darko. All rights reserved.
//

import Foundation


public class MaskRCNNConfig {
    
    public static let defaultConfig = MaskRCNNConfig()
    
    // TODO: generate the anchors on demand based on image shape, this will save 5mb
    public var anchorsURL: URL?
    public var compiledClassifierModelURL: URL?
    public var compiledMaskModelURL: URL?
}
