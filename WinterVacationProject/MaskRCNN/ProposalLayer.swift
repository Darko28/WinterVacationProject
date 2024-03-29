//
//  ProposalLayer.swift
//  WinterVacationProject
//
//  Created by Darko on 2019/2/1.
//  Copyright © 2019 Darko. All rights reserved.
//

import Foundation
import CoreML
import Accelerate


/**
 
 ProposalLayer is a Custom ML Layer that proposes regions of interests.
 
 ProposalLayer proposes regions of interest based on the probability of objects
 being detected in each region. Regions that overlap more than a given threshold
 are removed through a process caleed Non-Max Supression (NMS).
 
 Regions correspond to predefined "anchors" that are not inputs to the layer.
 Anchors are generated based on the image shape using a heuristic that maximizes the
 likelihood of bounding objects in the image. The process of generating anchors can
 be throught of as a hyperparameter.
 
 Anchors are adjusted using deltas provided as input to refine how they enclose the detected objects.
 
 The layer takes two inputs:
 
 - Probabilities of each region containing an object. Shape : (#regions, 2).
 - Anchor deltas to refine the anchors shape. Shape : (#regions, 4)
 
 The probabilities input's last dimension corresponds to the mutually exclusive
 probabilities of the region being background (index 0) or an object (index 1).
 
 The anchor deltas are layed out as follows : (dy, dx, log(dh), log(dw)).
 
 The layer takes four parameters:
 
 - boundingBoxRefinementStandardDeviation : Anchor deltas refinement standard deviation
 - preNMSMaxProposals : Maximum # of regions to evaluate for non max supression
 - maxProposals : Maximum # of regions to output
 - nmsIOUThreshold : Threshold below which to supress regions that overlap
 
 The layer has one output :
 
 - Regions of interest (y1, x1, y2, x2). Shape : (#regionsOut, 4)
 
 */
@available(iOS 12.0, macOS 10.14, *)
@objc(ProposalLayer) class ProposalLayer: NSObject, MLCustomLayer {
    
    var anchorData: Data!
    
    // Anchor deltas refinement standard deviation
    var boundingBoxRefinementStandardDeviation: [Float] = [0.1, 0.1, 0.2, 0.2]
    // Maximum # of regions to evaluate for non max supression
    var preNMSMaxProposals = 6000
    // Maximum # of regions to output
    var maxProposals = 1000
    // Threshold below which to supress regions that overlap
    var nmsIOUThreshold: Float = 0.7
    
    required init(parameters: [String : Any]) throws {
        super.init()
        
        self.anchorData = try Data(contentsOf: MaskRCNNConfig.defaultConfig.anchorsURL!)
        
        if let bboxStdDevCount = parameters["bboxStdDev_count"] as? Int {
            
            var bboxStdDev = [Float]()
            for i in 0..<bboxStdDevCount {
                if let bboxStdDevItem = parameters["bboxStdDev_\(i)"] as? Double {
                    bboxStdDev.append(Float(bboxStdDevItem))
                }
            }
            
            if (bboxStdDev.count == bboxStdDevCount) {
                self.boundingBoxRefinementStandardDeviation = bboxStdDev
            }
        }
        
        if let preNMSMaxProposals = parameters["preNMSMaxProposals"] as? Int {
            self.preNMSMaxProposals = preNMSMaxProposals
        }
        
        if let maxProposals = parameters["maxProposals"] as? Int {
            self.maxProposals = maxProposals
        }
        
        if let nmsIOUThreshold = parameters["nmsIOUThreshold"] as? Double {
            self.nmsIOUThreshold = Float(nmsIOUThreshold)
        }
    }
    
    func setWeightData(_ weights: [Data]) throws {
        // No-op
    }
    
    func outputShapes(forInputShapes inputShapes: [[NSNumber]]) throws -> [[NSNumber]] {
        var outputShape = inputShapes[1]
        outputShape[0] = NSNumber(integerLiteral: self.maxProposals)
        return [outputShape]
    }
    
    func evaluate(inputs: [MLMultiArray], outputs: [MLMultiArray]) throws {
        
        let log = OSLog(subsystem: "ProposalLayer", category: OSLog.Category.pointsOfInterest)
        os_signpost(OSSignpostType.begin, log: log, name: "Proposal-Eval")
        
        assert(inputs[0].dataType == MLMultiArrayDataType.float32)
        assert(inputs[1].dataType == MLMultiArrayDataType.float32)
        
        // Probabilities of each region containing an object. Shape : (#regions, 2).
        let classProbabilities = inputs[0]
        // Anchor deltas to refine the anchors shape. Shape : (#regions, 2)
        let anchorDeltas = inputs[1]
        
        let preNonMaxLimit = self.preNMSMaxProposals
        let maxProposals = self.maxProposals
        
        let totalNumberOfElements = Int(truncating: classProbabilities.shape[0])
        let numberOfElementsToProcess = min(totalNumberOfElements, preNonMaxLimit)
        
        os_signpost(OSSignpostType.begin, log: log, name: "Proposal-StridedSlice")
        // We extract only the object probabilities, which are always at the odd indices of the array
        let objectProbabilities = classProbabilities.floatDataPointer().stridedSlice(begin: 1, count: totalNumberOfElements, stride: 2)
        os_signpost(OSSignpostType.end, log: log, name: "Proposal-StridedSlice")
        
        os_signpost(OSSignpostType.begin, log: log, name: "Proposal-Sorting")
        // We sort the probabilities in descending order and get the index so as to reorder the other arrays.
        // We also clip to the limit.
        // This is the lowest operation of the layer, taking avg of 45ms on the ResNet101 backbone.
        // Would this be solved with a scatter/gather distributed merge sort? probably not
        let sortedProbabilityIndices = objectProbabilities.sortedIndices(ascending: false)[0 ..< numberOfElementsToProcess].toFloat()
        os_signpost(OSSignpostType.end, log: log, name: "Proposal-Sorting")
        
        os_signpost(OSSignpostType.begin, log: log, name: "Proposal-Gathering")
        
        // We broadcast the probability indices so that they index the boxes (anchor deltas and anchors)
        let boxElementLength = 4
        let boxIndices = broadcastedIndices(indices: sortedProbabilityIndices, toElementLength: boxElementLength)
        
        // We sort the deltas and the anchors
        
        var sortedDeltas: BoxArray = anchorDeltas.floatDataPointer().indexed(indices: boxIndices)
        
        var sortedAnchors: BoxArray = self.anchorData.withUnsafeBytes { (data: UnsafePointer<Float>) -> [Float] in
            return data.indexed(indices: boxIndices)
        }
        
        os_signpost(OSSignpostType.end, log: log, name: "Proposal-Gathering")
        
        os_signpost(OSSignpostType.begin, log: log, name: "Proposal-Compute")
        
        // For each element of deltas, multiply by stdev
        
        var stdDev = self.boundingBoxRefinementStandardDeviation
        let stdDevPointer = UnsafeMutablePointer<Float>(&stdDev)
        elementWiseMultiply(matrixPointer: UnsafeMutablePointer<Float>(&sortedDeltas), vectorPointer: stdDevPointer, height: numberOfElementsToProcess, width: stdDev.count)
        
        // We apply the box deltas and clip the results in place to the image boundaries
        let anchorsReference = sortedAnchors.boxReference()
        anchorsReference.applyBoxDeltas(sortedDeltas)
        anchorsReference.clip()
        os_signpost(OSSignpostType.end, log: log, name: "Proposal-Compute")
        
        // We apply Non Max Supression to the result boxes
        os_signpost(OSSignpostType.begin, log: log, name: "Proposal-NMS")
        
        let resultIndices = nonMaxSupression(boxes: sortedAnchors, indices: Array(0 ..< sortedAnchors.count), iouThreshold: self.nmsIOUThreshold, max: maxProposals)
        os_signpost(OSSignpostType.end, log: log, name: "Proposal-NMS")
        
        // We copy the result boxes corresponding to the resultIndices to the output
        os_signpost(OSSignpostType.begin, log: log, name: "Proposal-Copy")
        
        let output = outputs[0]
        let outputElementStride = Int(truncating: output.strides[0])
        
        for (i, resultIndex) in resultIndices.enumerated() {
            for j in 0..<4 {
                output[i*outputElementStride+j] = sortedAnchors[resultIndex*4+j] as NSNumber
            }
        }
        os_signpost(OSSignpostType.end, log: log, name: "Proposal-Copy")
        
        // Zero-pad the rest since CoreML does not erase the memory between evaluations
        
        let proposalCount = resultIndices.count
        let paddingCount = max(0, maxProposals-proposalCount)*outputElementStride
        output.padTailWithZeros(startIndex: proposalCount*outputElementStride, count: paddingCount)
        
        os_signpost(OSSignpostType.end, log: log, name: "Proposal-Eval")
    }
}
