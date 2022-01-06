struct Input{name, Tup <: NamedTuple}
    fields::Tup
end
Input{name}(fields::NamedTuple) where {name} = Input{name, typeof(fields)}(fields)
Input{name}(; kwargs...) where {name} = Input{name}((; kwargs...))

Base.propertynames(input::Input) = propertynames(getfield(input, :fields))
Base.getproperty(input::Input, name::Symbol) = getproperty(getfield(input, :fields), name)

Base.length(input::Input) = length(getfield(input, :fields))
Base.getindex(input::Input, name) = getindex(getfield(input, :fields), name)
Base.iterate(input::Input) = iterate(getfield(input, :fields))
Base.iterate(input::Input, state) = iterate(getfield(input, :fields), state)

Base.get(input::Input, name::Symbol, default) = get(getfield(input, :fields), name, default)
Base.haskey(input::Input, name::Symbol) = haskey(getfield(input, :fields), name)
Base.keys(input::Input) = keys(getfield(input, :fields))
Base.values(input::Input) = values(getfield(input, :fields))
Base.merge(tup::NamedTuple, input::Input) = merge(tup, getfield(input, :fields))
Base.show(io::IO, input::Input{name}) where {name} = print(io, "Input{:$name}", getfield(input, :fields))

getoftype(input::Input, name::Symbol, default)::typeof(default) = oftype(default, get(getfield(input, :fields), name, default))

##############
# Input TOML #
##############

_parse_input(name, x) = x
_parse_input(name, x::Vector) = first(x) isa Dict ? _parse_input.(name, x) : (x...,) # try vector => tuple except for table
_parse_input(name, x::Dict) = Input{name}(; (Symbol(key) => _parse_input(Symbol(key), value) for (key, value) in x)...)

function parse_input(x::Dict)
    for section in keys(x)
        preprocess! = Symbol(:preprocess_, section, :!)
        eval(preprocess!)(x[section])
    end
    _parse_input(:Root, x)
end

parse_inputfile(path::AbstractString) = parse_input(TOML.parsefile(path))
parse_inputstring(str::AbstractString) = parse_input(TOML.parse(str))

###########
# General #
###########

function preprocess_General!(General::Dict)
    if haskey(General, "coordinate_system")
        coordinate_system = General["coordinate_system"]
        if coordinate_system == "plane_strain"
            General["coordinate_system"] = PlaneStrain()
        elseif coordinate_system == "axisymmetric"
            General["coordinate_system"] = Axisymmetric()
        else
            throw(ArgumentError("wrong `coordinate_system`, got \"$coordinate_system\", use \"plane_strain\" or \"axisymmetric\""))
        end
    end
end

#####################
# BoundaryCondition #
#####################

function preprocess_BoundaryCondition!(BoundaryCondition::Dict)
end

function create_boundary_contacts(BoundaryCondition::Input{:BoundaryCondition})
    dict = Dict{Symbol, Contact}()
    for side in (:left, :right, :bottom, :top)
        if haskey(BoundaryCondition, side)
            coef = BoundaryCondition[side]
            coef = convert(Float64, coef isa AbstractString ? eval(Meta.parse(coef)) : coef)
            contact = Contact(:friction, coef)
        else
            contact = Contact(:slip)
        end
        dict[side] = contact
    end
    dict
end

#############
# SoilLayer #
#############

function preprocess_SoilLayer!(SoilLayer::Vector)
end

############
# Material #
############

const InputMaterial = Union{Input{:Material}, Input{:SoilLayer}}

function preprocess_Material!(Material::Vector)
    for mat in Material
        if haskey(mat, "region")
            mat["region"] = eval(Meta.parse(mat["region"])) # should be anonymous function
        end
        if haskey(mat, "type")
            mat["type"] = eval(Meta.parse(mat["type"]))
        end
        if haskey(mat, "friction_with_rigidbody")
            mat["friction_with_rigidbody"] = eval(Meta.parse(mat["friction_with_rigidbody"]))
        end
    end
end

function create_materialmodel(mat::InputMaterial, coordinate_system)
    create_materialmodel(mat.type, mat, coordinate_system)
end

function create_materialmodel(::Type{DruckerPrager}, params::InputMaterial, coordinate_system)
    E = params.youngs_modulus
    ν = params.poissons_ratio
    c = params.cohesion
    ϕ = params.friction_angle
    ψ = params.dilatancy_angle
    tension_cutoff = params.tension_cutoff
    elastic = LinearElastic(; E, ν)
    if coordinate_system isa PlaneStrain
        DruckerPrager(elastic, :plane_strain; c, ϕ, ψ, tension_cutoff)
    else
        DruckerPrager(elastic, :circumscribed; c, ϕ, ψ, tension_cutoff)
    end
end

function create_materialmodel(::Type{NewtonianFluid}, params::InputMaterial, coordinate_system)
    ρ0 = params.density
    P0 = params.pressure
    c = params.sound_of_speed
    μ = params.viscosity
    NewtonianFluid(; ρ0, P0, c, μ)
end

# This function is basically based on Material.Initialization
function initialize_stress!(σₚ::AbstractVector, material::Input{:Material}, g)
    Initialization = material.Initialization
    ρ0 = material.density
    if Initialization.type == "K0"
        for p in eachindex(σₚ)
            σ_y = -ρ0 * g * Initialization.reference_height
            σ_x = Initialization.K0 * σ_y
            σₚ[p] = (@Mat [σ_x 0.0 0.0
                           0.0 σ_y 0.0
                           0.0 0.0 σ_x]) |> symmetric
        end
    elseif Initialization.type == "uniform"
        for p in eachindex(σₚ)
            σₚ[p] = Initialization.mean_stress * one(σₚ[p])
        end
    else
        throw(ArgumentError("invalid initialization type, got $(Initialization.type)"))
    end
end

# Since initializing pointstate is dependent on types of simulation,
# `initialize!` phase should be given as argument.
# This `initialize!` function is called on each material to perform
# material-wise initialization.
# After initialization, these `pointstate`s will be concatenated.
# Then, if you have rigid bodies, the invalid points are removed.
function Poingr.generate_pointstate(initialize!::Function, ::Type{PointState}, grid::Grid, INPUT::Input{:Root}) where {PointState}
    # generate all pointstate first
    Material = INPUT.Material
    pointstates = map(1:length(Material)) do matindex
        material = Material[matindex]
        pointstate′ = generate_pointstate( # call method in `Poingr`
            material.region,
            PointState,
            grid;
            n = getoftype(INPUT.Advanced, :npoints_in_cell, 2),
        )
        initialize!(pointstate′, matindex)
        pointstate′
    end
    pointstate = first(pointstates)
    append!(pointstate, pointstates[2:end]...)

    # remove invalid pointstate
    α = getoftype(INPUT.Advanced, :contact_threshold_scale, 1.0)
    haskey(INPUT, :RigidBody) && deleteat!(
        pointstate,
        findall(eachindex(pointstate)) do p
            xₚ = pointstate.x[p]
            rₚ = pointstate.r[p]
            all(map(create_rigidbody, INPUT.RigidBody)) do rigidbody
                # remove pointstate which is in rigidbody or is in contact with rigidbody
                in(xₚ, rigidbody) || distance(rigidbody, xₚ, α * mean(rₚ)) !== nothing
            end
        end,
    )

    pointstate
end

#############
# RigidBody #
#############

function preprocess_RigidBody!(RigidBody::Vector)
    foreach(preprocess_RigidBody!, RigidBody)
end

function preprocess_RigidBody!(RigidBody::Dict)
    if haskey(RigidBody, "type")
        RigidBody["type"] = eval(Meta.parse(RigidBody["type"]))
    end
    if haskey(RigidBody, "control")
        if RigidBody["control"] === true
            # If the rigid body is controled, `density` should be `Inf`
            # to set `mass` into `Inf`.
            # This is necessary for computing effective mass.
            RigidBody["density"] = Inf # TODO: warning?
        end
    end
end

function create_rigidbody(RigidBody::Input{:RigidBody})
    create_rigidbody(RigidBody.type, RigidBody)
end

function create_rigidbody(::Type{Polygon}, params::Input{:RigidBody})
    rigidbody = GeometricObject(Polygon(Vec{2}.(params.coordinates)...))
    initialize_rigidbody!(rigidbody, params)
    rigidbody
end

function create_rigidbody(::Type{Circle}, params::Input{:RigidBody})
    rigidbody = GeometricObject(Circle(Vec(params.center), params.radius))
    initialize_rigidbody!(rigidbody, params)
    rigidbody
end

function initialize_rigidbody!(rigidbody::GeometricObject{dim, T}, params::Input{:RigidBody}) where {dim, T}
    rigidbody.m = area(rigidbody) * params.density # TODO: should use `volume`?
    rigidbody.v = getoftype(params, :velocity, zero(Vec{dim, T}))
    rigidbody.ω = getoftype(params, :angular_velocity, zero(Vec{3, T}))
    rigidbody
end

##########
# Output #
##########

function preprocess_Output!(Output::Dict)
end

############
# Advanced #
############

function preprocess_Advanced!(Advanced::Dict)
end
