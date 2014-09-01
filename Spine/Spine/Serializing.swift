//
//  Mapping.swift
//  Spine
//
//  Created by Ward van Teijlingen on 23-08-14.
//  Copyright (c) 2014 Ward van Teijlingen. All rights reserved.
//

import Foundation
import SwiftyJSON

typealias ResourceRepresentation = [String: AnyObject]

public class Serializer {
	
	var registeredClasses: [String: Resource.Type] = [:]
	
	public func registerType(type: Resource.Type) {
		let instance = type()
		self.registeredClasses[instance.resourceType] = type
	}
	
	private func classNameForResourceType(resourceType: String) -> Resource.Type {
		return self.registeredClasses[resourceType]!
	}

	func unserializeData(data: JSONValue) -> ResourceStore {
		let mappingOperation = UnserializeOperation(data: data, serializer: self)
		mappingOperation.start()
		return mappingOperation.result!
	}

	func unserializeData(data: JSONValue, usingStore store: ResourceStore) -> ResourceStore {
		let mappingOperation = UnserializeOperation(data: data, store: store, serializer: self)
		mappingOperation.start()
		return mappingOperation.result!
	}

	func serializeResources(resources: [Resource]) -> [String: [ResourceRepresentation]] {
		let mappingOperation = SerializeOperation(resources: resources)
		mappingOperation.start()
		return mappingOperation.result!
	}
}


// MARK: -

class UnserializeOperation: NSOperation {
	
	private var data: JSONValue
	private var store: ResourceStore
	private var serializer: Serializer
	
	private lazy var formatter = {
		Formatter()
	}()
	
	var result: ResourceStore?
	
	init(data: JSONValue, serializer: Serializer) {
		self.data = data
		self.serializer = serializer
		self.store = ResourceStore()
		super.init()
	}
	
	init(data: JSONValue, store: ResourceStore, serializer: Serializer) {
		self.data = data
		self.serializer = serializer
		self.store = store
		super.init()
	}
	
	override func main() {
		assert(self.data.object != nil, "The given JSON representation was not of type 'object' (dictionary).")
		
		for(resourceType: String, resourcesData: JSONValue) in self.data.object! {
			if resourceType == "linked" {
				for (linkedResourceType, linkedResources) in resourcesData.object! {
					for representation in linkedResources.array! {
						self.unserializeSingleRepresentation(representation, withResourceType: linkedResourceType)
					}
				}
			} else if let resources = resourcesData.array {
				for representation in resources {
					self.unserializeSingleRepresentation(representation, withResourceType: resourceType)
				}
			}
		}
		
		self.resolveRelations()
		
		self.result = self.store
	}

	/**
	Maps a single resource representation into a resource object of the given type.
	
	:param: representation The JSON representation of a single resource.
	:param: resourceType   The type of resource onto which to map the representation.
	*/
	private func unserializeSingleRepresentation(representation: JSONValue, withResourceType resourceType: String) {
		assert(representation.object != nil, "The given JSON representation was not of type 'object' (dictionary).")
		
		// Find existing resource in the store, or create a new resource.
		var resource: Resource
		var isExistingResource: Bool
		
		if let existingResource = self.store.resource(resourceType, identifier: representation["id"].string!) {
			resource = existingResource
			isExistingResource = true
		} else {
			resource = self.serializer.classNameForResourceType(resourceType)() as Resource
			isExistingResource = false
		}

		// Unserialize the representation into the resource object
		for (key, value) in representation.object! {
			if key == "links" {
				if let links = value.object {
					for (linkName, linkData) in links {
						if let id = linkData["id"].string {
							let relationship = ResourceRelationship.ToOne(href: linkData["href"].string!, ID: id, type: linkData["type"].string!)
							resource.relationships[linkName] = relationship
						}
						
						if let ids = linkData["ids"].array {
							let stringIDs: [String] = ids.map({ value in
								return value.string!
							})
							let relationship = ResourceRelationship.ToMany(href: linkData["href"].string!, IDs: stringIDs, type: linkData["type"].string!)
							resource.relationships[linkName] = relationship
						}
					}
				}
				
			} else if key == "id" {
				resource.resourceID = value.string
				
			} else if key == "href" {
				resource.resourceLocation = value.string
				
			} else {
				if let attribute = resource.persistentAttributes[key] {
					resource.setValue(self.formatter.unformatJSONValue(value, ofType: attribute), forKey: key)
				} else {
					resource.setValue(value.any, forKey: key)
				}
			}
		}
		
		if !isExistingResource {
			self.store.add(resource)
		}
	}
	
	/**
	Resolves the relations of the resources in the store.
	*/
	private func resolveRelations() {
		for resource in self.store.allResources() {
			
			for (relationshipName: String, relation: ResourceRelationship) in resource.relationships {
				
				switch relation {
				case .ToOne(let href, let ID, let type):
					// Find target of relation in store
					if let targetResource = store.resource(type, identifier: ID) {
						resource.setValue(targetResource, forKey: relationshipName)
					} else {
						// Target resource was not found in store, create a placeholder
						let placeholderResource = self.serializer.classNameForResourceType(type)() as Resource
						placeholderResource.resourceID = ID
						resource.setValue(placeholderResource, forKey: relationshipName)
					}
					
				case .ToMany(let href, let IDs, let type):
					var targetResources: [Resource] = []
					
					// Find targets of relation in store
					for ID in IDs {
						if let targetResource = store.resource(type, identifier: ID) {
							targetResources.append(targetResource)
						} else {
							// Target resource was not found in store, create a placeholder
							let placeholderResource = self.serializer.classNameForResourceType(type)() as Resource
							placeholderResource.resourceID = ID
							targetResources.append(placeholderResource)
						}
						
						resource.setValue(targetResources, forKey: relationshipName)
					}
				}
			}
		}
	}
}


// MARK: -

class SerializeOperation: NSOperation {
	
	private let resources: [Resource]
	private let formatter = Formatter()
	
	var result: [String: [ResourceRepresentation]]?
	
	init(resources: [Resource]) {
		self.resources = resources
	}
	
	override func main() {
		var dictionary: [String: [ResourceRepresentation]] = [:]
		
		//Loop through all resources
		for resource in resources {
			var properties: ResourceRepresentation = [:]
			var links: [String: AnyObject] = [:]
			
			// Special attributes
			if let ID = resource.resourceID {
				properties["id"] = ID
			}
			
			//Add the other persistent attributes to the representation
			for (attributeName, attribute) in resource.persistentAttributes {
				switch attribute {
				case .Property:
					properties[attributeName] = resource.valueForKey(attributeName)
					
				case .Date:
					properties[attributeName] = self.formatter.formatDate(resource.valueForKey(attributeName) as NSDate)
					
				case .ToOne:
					if let relatedResource = resource.valueForKey(attributeName) as? Resource {
						links[attributeName] = relatedResource.resourceID
					} else {
						links[attributeName] = NSNull()
					}
					
				case .ToMany:
					if let relatedResources = resource.valueForKey(attributeName) as? [Resource] {
						let IDs: [String] = relatedResources.map { (resource) in
							assert(resource.resourceID != nil, "Related resources must be saved before saving their parent resource.")
							return resource.resourceID!
						}
						links[attributeName] = IDs
					} else {
						links[attributeName] = []
					}
				}
			}
			
			//If links were found, add them to the representation
			if links.count != 0 {
				properties["links"] = links
			}
			
			//Add the resource representation to the root dictionary
			if dictionary[resource.resourceType] == nil {
				dictionary[resource.resourceType] = [properties]
			} else {
				dictionary[resource.resourceType]!.append(properties)
			}
		}
		
		self.result = dictionary
	}
}

// MARK: - Formatters
class Formatter {

	func unformatJSONValue(value: JSONValue, ofType type: ResourceAttribute) -> AnyObject {
		switch type {
		case .Date:
			return self.unformatDate(value.string!)
		default:
			return value.any!
		}
	}
	
	// MARK: Date
	
	private lazy var dateFormatter: NSDateFormatter = {
		let formatter = NSDateFormatter()
		formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
		return formatter
	}()

	private func formatDate(date: NSDate) -> String {
		return self.dateFormatter.stringFromDate(date)
	}

	private func unformatDate(value: String) -> NSDate {
		if let date = self.dateFormatter.dateFromString(value) {
			return date
		}
		
		return NSDate()
	}
}