package ecs

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"

// Type Definitions
EntityID :: distinct u64
ArchetypeID :: u64
ComponentID :: EntityID

// Errors
Error :: enum {
	None,
	EntityNotFound,
	ComponentNotFound,
	ArchetypeNotFound,
	ComponentDataOutOfBounds,
	InvalidComponentID,
	EntityAlreadyExists,
	ComponentAlreadyExists,
	ComponentDisabled,
	OperationFailed,
}

Result :: union($T: typeid) {
	T,
	Error,
}

// Component Type Registry
ComponentTypeInfo :: struct {
	size:      int,
	type_info: ^reflect.Type_Info,
}

// Size of Type_Info
size_of_type :: proc(type_info: ^reflect.Type_Info) -> int {
	return int(runtime.type_info_base(type_info).size)
}

get_component_id :: proc(world: ^World, T: typeid) -> (ComponentID, bool) {
	return world.component_ids[T]
}

World :: struct {
	component_info:       map[ComponentID]ComponentTypeInfo,
	info_component:       map[ComponentTypeInfo]ComponentID,
	component_ids:        map[typeid]ComponentID,
	pair_component_ids:   map[EntityID]ComponentID,
	entity_index:         map[EntityID]EntityInfo,
	archetypes:           map[ArchetypeID]^Archetype,
	component_archetypes: map[ComponentID]map[ArchetypeID]^Archetype,
	next_entity_id:       EntityID,
	queries:              [dynamic]^Query,
}

// Entity Info stores the location of an entity within an archetype and its version
// TODO: store version in upper 16 bits of entity ID
// TODO: if entity ID is a Pair: store relationship target in lower 16 bits and relation id in upper 16 bits

Wildcard :: distinct struct {}

PairType :: struct($R, $T: typeid) {
	relation: R,
	target:   T,
}

EntityInfo :: struct {
	archetype: ^Archetype,
	row:       int,
	version:   u32,
}

Query :: struct {
	component_ids: []ComponentID,
	archetypes:    [dynamic]^Archetype,
}

Archetype :: struct {
	id:               ArchetypeID,
	component_ids:    []ComponentID,
	tag_ids:          []ComponentID,
	component_types:  map[ComponentID]^reflect.Type_Info,
	entities:         [dynamic]EntityID,
	tables:           map[ComponentID][dynamic]byte,
	disabled_set:     map[ComponentID]bool,
	matching_queries: [dynamic]^Query,
	add_edges:        map[ComponentID]^Archetype,
	remove_edges:     map[ComponentID]^Archetype,
}

create_world :: proc() -> ^World {
	world := new(World)
	world.component_info = make(map[ComponentID]ComponentTypeInfo)
	world.entity_index = make(map[EntityID]EntityInfo)
	world.archetypes = make(map[ArchetypeID]^Archetype)
	world.component_archetypes = make(map[ComponentID]map[ArchetypeID]^Archetype)
	world.next_entity_id = EntityID(1)
	world.queries = make([dynamic]^Query)
	return world
}

new_world :: create_world

delete_world :: proc(world: ^World) {
	if world == nil {
		return
	}

	for _, archetype in world.archetypes {
		delete_archetype(archetype)
	}
	delete(world.component_info)
	delete(world.info_component)
	delete(world.component_ids)
	delete(world.pair_component_ids)
	delete(world.entity_index)
	delete(world.archetypes)
	for _, comp_map in world.component_archetypes {
		delete(comp_map)
	}
	delete(world.component_archetypes)
	delete(world.queries)
	free(world)
}


register_component :: proc {
	register_component_typeid,
// register_component_type,
}

register_component_typeid :: proc(world: ^World, T: typeid) -> ComponentID {
	id := add_entity(world)
	type_info := type_info_of(T)
	info := ComponentTypeInfo {
		size      = size_of_type(type_info),
		type_info = type_info,
	}
	world.component_info[id] = info
	world.info_component[info] = id
	world.component_ids[type_info.id] = id
	return id
}

register_component_type :: proc(world: ^World, $T: typeid) -> ComponentID {
	id := add_entity(world)
	type_info := type_info_of(T)
	info := ComponentTypeInfo {
		size      = size_of_type(type_info),
		type_info = type_info,
	}
	world.component_info[id] = info
	world.info_component[info] = id
	world.component_ids[type_info.id] = id
	return id
}

add_entity :: proc(world: ^World) -> EntityID {
	entity := world.next_entity_id
	world.next_entity_id = world.next_entity_id + 1

	// TODO: pack version etc into ID bits
	if info, exists := &world.entity_index[entity]; exists {
		info.archetype = nil
		info.row = -1
		info.version += 1
	} else {
		world.entity_index[entity] = EntityInfo {
			archetype = nil,
			row       = -1,
			version   = 0,
		}
	}
	return entity
}

create_entity :: add_entity

remove_entity :: proc(world: ^World, entity: EntityID) {
	info, ok := &world.entity_index[entity]
	if !ok || info.archetype == nil {
		return // Entity does not exist or has already been removed
	}

	archetype := info.archetype
	row := info.row
	last_row := len(archetype.entities) - 1

	// Swap the entity to be removed with the last entity in the archetype
	if row != last_row {
		last_entity := archetype.entities[last_row]
		archetype.entities[row] = last_entity

		// Update all component tables
		for component_id, &component_array in &archetype.tables {
			if slice.contains(archetype.tag_ids, component_id) {
				continue // Skip tags as they don't have data
			}

			type_info := archetype.component_types[component_id]
			size := size_of_type(type_info)

			// Move the last element's data to the removed entity's position
			mem.copy(&component_array[row * size], &component_array[last_row * size], size)
		}

		// Update the moved entity's index
		if moved_info, exists := &world.entity_index[last_entity]; exists {
			moved_info.row = row
		}
	}

	// Remove the last entity (which is now the entity we want to remove)
	pop(&archetype.entities)

	// Resize all component arrays
	for component_id, &component_array in &archetype.tables {
		if slice.contains(archetype.tag_ids, component_id) {
			continue // Skip tags as they don't have data
		}

		type_info := archetype.component_types[component_id]
		size := size_of_type(type_info)

		resize(&component_array, len(archetype.entities) * size)
	}

	// Recycle the entity
	info.archetype = nil
	info.row = -1
	info.version += 1
	world.next_entity_id = entity

	// If the archetype is now empty, remove it from the world
	if len(archetype.entities) == 0 {
		delete_key(&world.archetypes, archetype.id)
		for component_id in archetype.component_ids {
			if component_archetypes, ok := &world.component_archetypes[component_id]; ok {
				delete_key(component_archetypes, archetype.id)
			}
		}
		delete_archetype(archetype)
	}
}

delete_entity :: remove_entity

entity_exists :: proc(world: ^World, entity: EntityID) -> bool {
	info, ok := world.entity_index[entity]
	return ok && info.archetype != nil
}

entity_alive :: entity_exists

has_component :: proc {
	has_component_type,
	has_component_instance,
}

has_component_type :: proc(world: ^World, entity: EntityID, $T: typeid) -> bool {
	info, exists := world.entity_index[entity]
	if !exists || info.archetype == nil {
		return false
	}

	cid, ok := get_component_id(world, T)
	if !ok {
		return false
	}
	return slice.contains(info.archetype.component_ids, cid)
}

has_component_instance :: proc(world: ^World, entity: EntityID, component: $T) -> bool {
	info, exists := world.entity_index[entity]
	if !exists || info.archetype == nil {
		return false
	}

	cid, ok := get_component_id(world, T)
	if !ok {
		return false
	}
	return slice.contains(info.archetype.component_ids, cid)
}

get_relation_typeid :: proc(c: PairType($R, $T)) -> typeid {
	return typeid_of(R)
}

get_relation_type :: proc(c: PairType($R, $T)) -> typeid {
	return R
}

add_component :: proc(world: ^World, entity: EntityID, component: $T) {
    cid: ComponentID
    ok: bool

    when intrinsics.type_is_struct(T) && intrinsics.type_has_field(T, "relation") && intrinsics.type_has_field(T, "target") {
        relation_cid: ComponentID
        target_cid: ComponentID

        when type_of(component.relation) == EntityID {
            relation_cid = ComponentID(component.relation)
        } else {
            relation_cid, ok = get_component_id(world, type_of(component.relation))
            if !ok {
                relation_cid = register_component(world, type_of(component.relation))
            }
        }

        when type_of(component.target) == EntityID {
            target_cid = ComponentID(component.target)
        } else {
            target_cid, ok = get_component_id(world, type_of(component.target))
            if !ok {
                target_cid = register_component(world, type_of(component.target))
            }
        }

        cid = hash_pair(relation_cid, target_cid)

        pair_type_info := type_info_of(T)
        world.component_info[cid] = ComponentTypeInfo{
            size      = size_of(T),
            type_info = pair_type_info,
        }
    } else {
        cid, ok = get_component_id(world, T)
        if !ok {
            cid = register_component(world, T)
        }
    }

    info := world.entity_index[entity]
    old_archetype := info.archetype
    new_archetype: ^Archetype

    if old_archetype == nil {
        new_component_ids: [1]ComponentID = {cid}
        new_tag_ids: [1]ComponentID
        tag_count := 0
        if size_of(T) == 0 {
            new_tag_ids[0] = cid
            tag_count = 1
        }
        
        new_archetype = get_or_create_archetype(world, new_component_ids[:], new_tag_ids[:])
        
        move_entity(world, entity, info, nil, new_archetype)
    } else {
        new_archetype, ok = old_archetype.add_edges[cid]
        if !ok {
            new_component_ids: [dynamic]ComponentID
			defer delete(new_component_ids)
            append(&new_component_ids, ..old_archetype.component_ids)
            append(&new_component_ids, cid)
            sort_component_ids(new_component_ids[:])

            new_tag_ids: [dynamic]ComponentID
			defer delete(new_tag_ids)
            append(&new_tag_ids, ..old_archetype.tag_ids)
            if size_of(T) == 0 {
                append(&new_tag_ids, cid)
            }

            new_archetype = get_or_create_archetype(world, new_component_ids[:], new_tag_ids[:])
            
            old_archetype.add_edges[cid] = new_archetype
        }

        move_entity(world, entity, info, old_archetype, new_archetype)
    }

    when size_of(T) > 0 {
        index := world.entity_index[entity].row
        local_component := component

        when intrinsics.type_is_struct(T) && intrinsics.type_has_field(T, "relation") && intrinsics.type_has_field(T, "target") {
            add_component_data(
                new_archetype,
                cid,
                rawptr(&local_component),
                index,
                type_of(component.relation),
            )
        } else {
            add_component_data(new_archetype, cid, rawptr(&local_component), index, T)
        }
    }
}

add_component_data :: proc(
	archetype: ^Archetype,
	component_id: ComponentID,
	component: rawptr,
	index: int,
	$T: typeid,
) {
	table, ok := &archetype.tables[component_id]
	if !ok {
		return
	}

	size := size_of(T)
	if size == 0 {
		return // Skip tags as they don't have data
	}

	required_size := (index + 1) * size
	if len(table^) < required_size {
		resize(table, required_size)
	}

	offset := index * size

	mem.copy(&table^[offset], component, size)
}

remove_component_id :: proc(ids: []ComponentID, cid: ComponentID) -> []ComponentID {
	new_ids: [dynamic]ComponentID
	for id in ids {
		if u64(id) != u64(cid) {
			append(&new_ids, id)
		}
	}
	return new_ids[:]
}

remove_component :: proc(world: ^World, entity: EntityID, $T: typeid) {
	cid, ok := get_component_id(world, T)
	if !ok {
		return
	}
	info := world.entity_index[entity]

	old_archetype := info.archetype
	if old_archetype == nil {
		return // Entity does not have this component
	}

	// Check if the component exists in the archetype
	if !slice.contains(old_archetype.component_ids, cid) {
		return // Component not present
	}

	// Use the remove_edges graph to get the next archetype
	new_archetype, ok2 := old_archetype.remove_edges[cid]
	if !ok2 {
		// If the edge doesn't exist, create a new archetype
		new_component_ids := remove_component_id(old_archetype.component_ids, cid)
		defer delete(new_component_ids)

		new_tag_ids: [dynamic]ComponentID
		defer delete(new_tag_ids)
		for tag_id in old_archetype.tag_ids {
			if tag_id != cid {
				append(&new_tag_ids, tag_id)
			}
		}

		new_archetype = get_or_create_archetype(world, new_component_ids[:], new_tag_ids[:])
		old_archetype.remove_edges[cid] = new_archetype
	}

	// Move entity to new archetype
	move_entity(world, entity, info, old_archetype, new_archetype)
}

disable_component :: proc(world: ^World, entity: EntityID, $T: typeid) {
	cid, ok := get_component_id(world, T)
	if !ok {
		return // Component not registered
	}

	info, exists := world.entity_index[entity]
	if !exists {
		return // Entity not found
	}

	archetype := info.archetype
	if archetype == nil {
		return // Entity has no archetype
	}

	if !slice.contains(archetype.component_ids, cid) {
		return // Component not present in archetype
	}

	archetype.disabled_set[cid] = true
}

enable_component :: proc(world: ^World, entity: EntityID, $T: typeid) {
	component_id, ok := get_component_id(world, T)
	if !ok {
		return // Component not registered
	}

	info, exists := world.entity_index[entity]
	if !exists {
		return // Entity not found
	}

	archetype := info.archetype
	if archetype == nil {
		return // Entity has no archetype
	}

	if !slice.contains(archetype.component_ids, component_id) {
		return // Component not present in archetype
	}

	delete_key(&archetype.disabled_set, component_id)
}

move_entity :: proc(
	world: ^World,
	entity: EntityID,
	info: EntityInfo,
	old_archetype: ^Archetype,
	new_archetype: ^Archetype,
) {
	// Add to new archetype
	new_row := len(new_archetype.entities)
	append(&new_archetype.entities, entity)

	// Update entity index
	world.entity_index[entity] = EntityInfo {
		archetype = new_archetype,
		row       = new_row,
		version   = info.version,
	}

	// Resize and copy shared component data
	for component_id in new_archetype.component_ids {
		if slice.contains(new_archetype.tag_ids, component_id) {
			continue // Tags don't have data, so we skip them
		}

		new_table, ok := &new_archetype.tables[component_id]
		if !ok {
			new_table^ = make([dynamic]byte)
			new_archetype.tables[component_id] = new_table^
		}
		type_info := new_archetype.component_types[component_id]
		size := size_of_type(type_info)

		// Ensure new_table is big enough
		if len(new_table^) < (new_row + 1) * size {
			resize(new_table, (new_row + 1) * size)
		}

		new_offset := new_row * size

		if old_archetype != nil {
			if old_table, exists := old_archetype.tables[component_id];
			   exists && len(old_table) > 0 {
				// Copy component data from old to new
				old_offset := info.row * size
				if old_offset < len(old_table) && new_offset < len(new_table^) {
					mem.copy(&new_table[new_offset], &old_table[old_offset], size)
				}
			} else {
				// Initialize new component data to zero
				mem.zero(&new_table[new_offset], size)
			}
		} else {
			// Initialize new component data to zero
			mem.zero(&new_table[new_offset], size)
		}
	}

	// Remove from old archetype if necessary
	if old_archetype != nil && info.row >= 0 {
		old_row := info.row
		last_index := len(old_archetype.entities) - 1

		if old_row != last_index {
			// Swap with the last entity
			last_entity := old_archetype.entities[last_index]
			old_archetype.entities[old_row] = last_entity

			// Update component tables
			for component_id, &table in &old_archetype.tables {
				if slice.contains(old_archetype.tag_ids, component_id) {
					continue // Skip tags as they don't have data
				}

				type_info := old_archetype.component_types[component_id]
				size := size_of_type(type_info)

				// Move last element to the removed position
				mem.copy(&table[old_row * size], &table[last_index * size], size)

				// Shrink the table
				resize(&table, (last_index) * size)
			}

			// Update entity index for the moved entity
			if entity_info, exists := &world.entity_index[last_entity]; exists {
				entity_info.row = old_row
			}
		} else {
			// If it's the last entity, just remove it from all tables
			for component_id, &table in &old_archetype.tables {
				if slice.contains(old_archetype.tag_ids, component_id) {
					continue // Skip tags as they don't have data
				}

				type_info := old_archetype.component_types[component_id]
				size := size_of_type(type_info)

				// Shrink the table
				resize(&table, (last_index) * size)
			}
		}

		// Remove the last entity
		pop(&old_archetype.entities)

	}

	// If the old archetype exists and has 0 entities, remove it
	// TODO: probably should make this manual, as recreating archetypes is expensive
	if old_archetype != nil && len(old_archetype.entities) == 0 {
		delete_key(&world.archetypes, old_archetype.id)
		delete_archetype(old_archetype)
		// TODO: remove from queries
	}
}

get_or_create_archetype :: proc(
	world: ^World,
	component_ids: []ComponentID,
	tag_ids: []ComponentID,
) -> ^Archetype {
	archetype_id := hash_archetype(component_ids, tag_ids)
	archetype, exists := world.archetypes[archetype_id]
	if exists {
		return archetype
	}

	// Create new archetype
	archetype = new(Archetype)
	archetype.id = archetype_id
	archetype.component_ids = slice.clone(component_ids)
	archetype.entities = make([dynamic]EntityID)
	archetype.tables = make(map[ComponentID][dynamic]byte)
	archetype.component_types = make(map[EntityID]^reflect.Type_Info)
	archetype.tag_ids = slice.clone(tag_ids)
	archetype.disabled_set = make(map[ComponentID]bool)
	archetype.add_edges = make(map[ComponentID]^Archetype)
	archetype.remove_edges = make(map[ComponentID]^Archetype)
	// Initialize component arrays and update component archetypes
	for cid in component_ids {
		component_info := world.component_info[cid]
		if component_info.size > 0 {
			// Only allocate storage for components with data
			new_table := make([dynamic]byte)
			archetype.tables[cid] = new_table
			archetype.component_types[cid] = component_info.type_info
		}
	}

	// Add to archetypes map
	world.archetypes[archetype_id] = archetype

	return archetype
}

delete_archetype :: proc(archetype: ^Archetype) {
	if archetype == nil {
		return
	}

	for _, other_archetype in archetype.add_edges {
		for key, a in other_archetype.add_edges {
			if a.id == archetype.id do delete_key(&other_archetype.add_edges, key)
		}
		for key, a in other_archetype.remove_edges {
			if a.id == archetype.id do delete_key(&other_archetype.remove_edges, key)
		}
	}
	
	for _, other_archetype in archetype.remove_edges {
		for key, a in other_archetype.add_edges {
			if a.id == archetype.id do delete_key(&other_archetype.add_edges, key)
		}
		for key, a in other_archetype.remove_edges {
			if a.id == archetype.id do delete_key(&other_archetype.remove_edges, key)
		}
	}

	delete(archetype.component_ids)
	delete(archetype.entities)
	for _, array in archetype.tables {
		delete(array)
	}
	delete(archetype.tables)
	delete(archetype.component_types)
	delete(archetype.tag_ids)
	delete(archetype.disabled_set)
	delete(archetype.add_edges)
	delete(archetype.remove_edges)
	free(archetype)
}

sort_component_ids :: proc(ids: []ComponentID) {
	// Simple insertion sort for small arrays
	for i := 1; i < len(ids); i += 1 {
		key := ids[i]
		j := i - 1
		for j >= 0 && ids[j] > key {
			ids[j + 1] = ids[j]
			j -= 1
		}
		ids[j + 1] = key
	}
}

hash_archetype :: proc(
	component_ids: []ComponentID,
	tag_ids: []ComponentID,
) -> ArchetypeID {
	h := u64(14695981039346656037) // FNV-1a 64-bit offset basis

	// Sort and hash component_ids in-place
	sort_component_ids(component_ids)
	for id in component_ids {
		h = (h ~ u64(id)) * 1099511628211
	}

	// Sort and hash tag_ids in-place
	sort_component_ids(tag_ids)
	for id in tag_ids {
		h = (h ~ u64(id)) * 1099511628211
	}

	return ArchetypeID(h)
}

get_component :: proc {
    get_component_same,
    get_component_cast,
    get_component_pair,
}

get_component_same :: proc(world: ^World, entity: EntityID, $Component: typeid) -> ^Component {
    info := world.entity_index[entity]
    cid, ok := get_component_id(world, Component)
    if !ok {
        return nil
    }
    
    archetype := info.archetype
    if archetype == nil {
        return nil
    }
    
    table, exists := archetype.tables[cid]
    if !exists {
        return nil
    }
    
    row := info.row
    component_size := size_of(Component)
    
    if len(table) == 0 {
        return nil
    }
    
    num_components := len(table) / component_size
    if row >= num_components {
        return nil
    }
    
    components := (cast(^[dynamic]Component)(&table))[:num_components]
    return ^components[row]
}

get_component_cast :: proc(world: ^World, entity: EntityID, $Component: typeid, $CastTo: typeid) -> ^CastTo {
    info := world.entity_index[entity]
    cid, ok := get_component_id(world, Component) 
    if !ok {
        return nil
    }
    
    archetype := info.archetype
    if archetype == nil {
        return nil
    }
    
    table, exists := archetype.tables[cid]
    if !exists {
        return nil
    }
    
    row := info.row
    component_size := size_of(CastTo)
    
    if len(table) == 0 {
        return nil
    }
    
    num_components := len(table) / component_size
    if row >= num_components {
        return nil
    }
    
    components := (cast(^[dynamic]CastTo)(&table))[:num_components]
    return ^components[row]
}

get_component_pair :: proc(world: ^World, entity: EntityID, pair: PairType($R, $T)) -> ^R {
    info := world.entity_index[entity]
    relation_cid, relation_ok := get_component_id(world, R)
    target_cid, target_ok := get_component_id(world, T)
    
    if !relation_ok || !target_ok {
        return nil
    }
    
    pair_cid := hash_pair(relation_cid, target_cid)
    table, exists := archetype.tables[pair_cid]
    if !exists {
        return nil
    }
    
    row := info.row
    component_size := size_of(R)
    
    if len(table) == 0 {
        return nil
    }
    
    num_components := len(table) / component_size
    if row >= num_components {
        return nil
    }
    
    components := (cast(^[dynamic]R)(&table))[:num_components]
    return ^components[row]
}

get_table :: proc {
	get_table_same,
	get_table_cast,
	get_table_pair,
}

get_table_pair :: proc(world: ^World, archetype: ^Archetype, pair: PairType($R, $T)) -> []R {
    relation_cid, relation_ok := get_component_id(world, R)
    target_cid, target_ok := get_component_id(world, T)
    
    if !relation_ok || !target_ok {
        return nil
    }
    
    pair_cid := hash_pair(relation_cid, target_cid)
    table, exists := archetype.tables[pair_cid]
    
    if !exists {
        return nil
    }
    
    component_size := size_of(R)
    num_components := len(table) / component_size
    return (cast(^[dynamic]R)(&table))[:num_components]
}


get_table_same :: proc(world: ^World, archetype: ^Archetype, $Component: typeid) -> []Component {
	cid, ok := get_component_id(world, Component)
	if !ok {
		return nil
	}
	table, exists := archetype.tables[cid]
	if !exists {
		return nil
	}

	component_size := size_of(Component)
	num_components := len(table) / component_size
	return (cast(^[dynamic]Component)(&table))[:num_components]
}

get_table_cast :: proc(
	world: ^World,
	archetype: ^Archetype,
	$Component: typeid,
	$CastTo: typeid,
) -> []CastTo {
	cid, ok := get_component_id(world, Component)
	if !ok {
		return nil
	}
	table, exists := archetype.tables[cid]
	if !exists {
		return nil
	}

	component_size := size_of(CastTo)
	num_components := len(table) / component_size
	return (cast(^[dynamic]CastTo)(&table))[:num_components]
}

get_table_row :: proc(world: ^World, entity_id: EntityID) -> int {
	if info, ok := world.entity_index[entity_id]; ok {
		return info.row
	}
	return -1
}

// Query builder structure
QueryBuilder :: struct {
	world: ^World,
	terms: [dynamic]Term,
}

Term :: union {
	HasTerm,
	NotTerm,
	PairType(typeid, typeid),
	PairType(EntityID, EntityID),
	PairType(EntityID, typeid),
	PairType(typeid, EntityID),
}

HasTerm :: struct {
	component: union {
		typeid,
		PairType(typeid, typeid),
		PairType(EntityID, EntityID),
		PairType(EntityID, typeid),
		PairType(typeid, EntityID),
	},
}

NotTerm :: struct {
	component: union {
		typeid,
		PairType(typeid, typeid),
		PairType(EntityID, EntityID),
		PairType(EntityID, typeid),
		PairType(typeid, EntityID),
	},
}

// Initialize a new query builder
new_query :: proc(world: ^World) -> QueryBuilder {
	return QueryBuilder{world = world, terms = make([dynamic]Term, context.temp_allocator)}
}

execute :: proc(q: ^QueryBuilder) -> []^Archetype {
	if len(q.terms) == 0 {
		return nil
	}

	has_terms: [dynamic]ComponentID
	not_terms: [dynamic]ComponentID
	defer delete(has_terms)
	defer delete(not_terms)

	for term in q.terms {
		cid: ComponentID
		ok: bool

		switch t in term {
		case HasTerm:
			switch component in t.component {
			case typeid:
				cid, ok = get_component_id_from_term_typeid(q.world, component)
			case PairType(typeid, typeid):
				cid, ok = get_component_id_from_term_pair_typeid_typeid(q.world, component)
			case PairType(EntityID, EntityID):
				cid, ok = get_component_id_from_term_pair_entity_entity(q.world, component)
			case PairType(EntityID, typeid):
				cid, ok = get_component_id_from_term_pair_entity_typeid(q.world, component)
			case PairType(typeid, EntityID):
				cid, ok = get_component_id_from_term_pair_typeid_entity(q.world, component)
			}
			if ok {
				append(&has_terms, cid)
			}
		case NotTerm:
			switch component in t.component {
			case typeid:
				cid, ok = get_component_id_from_term_typeid(q.world, component)
			case PairType(typeid, typeid):
				cid, ok = get_component_id_from_term_pair_typeid_typeid(q.world, component)
			case PairType(EntityID, EntityID):
				cid, ok = get_component_id_from_term_pair_entity_entity(q.world, component)
			case PairType(EntityID, typeid):
				cid, ok = get_component_id_from_term_pair_entity_typeid(q.world, component)
			case PairType(typeid, EntityID):
				cid, ok = get_component_id_from_term_pair_typeid_entity(q.world, component)
			}
			if ok {
				append(&not_terms, cid)
			}
		case PairType(typeid, typeid):
			cid, ok = get_component_id_from_pair(q.world, t)
			if ok {
				append(&has_terms, cid)
			}
		case PairType(EntityID, EntityID):
			cid, ok = get_component_id_from_pair(q.world, t)
			if ok {
				append(&has_terms, cid)
			}
		case PairType(EntityID, typeid):
			cid, ok = get_component_id_from_pair(q.world, t)
			if ok {
				append(&has_terms, cid)
			}
		case PairType(typeid, EntityID):
			cid, ok = get_component_id_from_pair(q.world, t)
			if ok {
				append(&has_terms, cid)
			}
		}

		if !ok {
			return []^Archetype{}
		}
	}

	result := make([dynamic]^Archetype, context.temp_allocator)
	for _, archetype in q.world.archetypes {
		all_has_present := true
		for id in has_terms {
			if !slice.contains(archetype.component_ids, id) {
				all_has_present = false
				break
			}
		}

		no_not_present := true
		for id in not_terms {
			if slice.contains(archetype.component_ids, id) {
				no_not_present = false
				break
			}
		}

		if all_has_present && no_not_present {
			append(&result, archetype)
		}
	}

	return result[:]
}

get_component_id_from_term :: proc {
    get_component_id_from_term_typeid,
    get_component_id_from_term_pair_typeid_typeid,
    get_component_id_from_term_pair_typeid_entity,
    get_component_id_from_term_pair_entity_typeid,
    get_component_id_from_term_pair_entity_entity,
}

get_component_id_from_term_typeid :: proc(world: ^World, component: typeid) -> (ComponentID, bool) {
    return get_component_id(world, component)
}

get_component_id_from_term_pair_typeid_typeid :: proc(world: ^World, component: PairType(typeid, typeid)) -> (ComponentID, bool) {
    return get_component_id_from_pair(world, component)
}

get_component_id_from_term_pair_typeid_entity :: proc(world: ^World, component: PairType(typeid, EntityID)) -> (ComponentID, bool) {
    return get_component_id_from_pair(world, component)
}

get_component_id_from_term_pair_entity_typeid :: proc(world: ^World, component: PairType(EntityID, typeid)) -> (ComponentID, bool) {
    return get_component_id_from_pair(world, component)
}

get_component_id_from_term_pair_entity_entity :: proc(world: ^World, component: PairType(EntityID, EntityID)) -> (ComponentID, bool) {
    return get_component_id_from_pair(world, component)
}

get_type_id_from_type_or_struct :: proc(value: $T) -> typeid {
	when T == typeid {
		return type_info_of(value).id
	} else {
		return type_info_of(typeid_of(T)).id
	}
}

get_relation_from_pair :: proc(pair: $P/PairType) -> union{EntityID, typeid} {
	return pair.relation
}

get_target_from_pair :: proc(pair: $P/PairType) -> union{EntityID, typeid} {
	return pair.target
}

get_component_id_from_pair :: proc(world: ^World, pair: $P/PairType) -> (ComponentID, bool) {
    relation := get_relation_from_pair(pair)
    relation_cid: ComponentID
    
    // Handle relation
    switch r in relation {
    case EntityID:
        relation_cid = ComponentID(r)
    case typeid:
        ok: bool
        relation_cid, ok = get_component_id(world, r)
        if !ok {
            return 0, false
        }
    case:
        // fmt.println("Unknown relation type")
        return 0, false
    }

    target := get_target_from_pair(pair)
    target_cid: ComponentID
    
    
    // Handle target
    switch t in target {
    case EntityID:
        target_cid = ComponentID(t)
    case typeid:
        ok: bool
        target_cid, ok = get_component_id(world, t)
        if !ok {
            return 0, false
        }
    case:
        return 0, false
    }

    result := hash_pair(relation_cid, target_cid)
    return result, true
}

hash_pair :: proc(relation_cid, target_cid: ComponentID) -> ComponentID {
	return ComponentID(u64(relation_cid) << 32 | u64(target_cid))
}

has :: proc {
	has_typeid,
	has_pair,
}

has_typeid :: proc(component: typeid) -> Term {
	return HasTerm{component}
}

has_pair :: proc(p: $P/PairType) -> Term {
	return HasTerm{p}
}

not :: proc {
	not_typeid,
	not_pair,
}

not_typeid :: proc(component: typeid) -> Term {
	return NotTerm{component}
}

not_pair :: proc(p: $P/PairType) -> Term {
	return NotTerm{p}
}

query :: proc(world: ^World, terms: ..Term) -> []^Archetype {
	q := new_query(world)
	for term in terms {
		append(&q.terms, term)
	}
	return execute(&q)
}


pair :: proc {
    pair_generic,
    pair_typeid_entity,
    pair_entity_typeid,
    pair_typeid_typeid,
}

pair_generic :: proc(r: $R, t: $T) -> PairType(R, T) {
    return PairType(R, T){r, t}
}

pair_typeid_entity :: proc(r: typeid, t: EntityID) -> PairType(typeid, EntityID) {
    return PairType(typeid, EntityID){r, t}
}

pair_entity_typeid :: proc(r: EntityID, t: typeid) -> PairType(EntityID, typeid) {
    return PairType(EntityID, typeid){r, t}
}

pair_typeid_typeid :: proc(r: typeid, t: typeid) -> PairType(typeid, typeid) {
    return PairType(typeid, typeid){r, t}
}
