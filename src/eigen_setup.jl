## data
# Tshuapa province data, 2011-2015
tshuapa_h2hag = aggregatecategories(readJSON(:tshuapa2015_h2h))

# Endemic provinces in DRC, 2024
ageint = [0:5:15;20:10:50]
drc_endemic_ag = aggregateagegroups(aggregatecategories(readJSON(:drc_endemic_Aug2024)),ageint)



## functions
function parameterise(cmt, susfunc::Function) # for zmb
    param_dict = Dict(pairs((s_infant=fill(1.),s_baseline=fill(1.),s_partvax=fill(1.),s_vax=fill(1.))))
    cmskeleton = deepcopy(cmt)
    for cm in cmskeleton
        cm.parameters = deepcopy(param_dict)
        setsusceptibility!(cm, susfunc)
    end
    cmskeleton
end
function parameterise(cmt, vaccinethreshold::Number) # for drc
    thr_ind=vaccinethreshold÷5
    param_dict = Dict(pairs((s_infant=fill(1.),s_baseline=fill(1.),s_partvax=fill(1.),s_vax=fill(1.))))
    cmskeleton = deepcopy(cmt)
    for cm in cmskeleton
        cm.parameters = deepcopy(param_dict)
        setsusceptibility!(cm,getindex.(Ref(cm.parameters),[:s_infant;fill(:s_baseline,thr_ind-1);fill(:s_vax,16-thr_ind)]))
    end
    cmskeleton
end
function addsexualcontact!(cmt::ContactMatrix, activeage = 10:10:40; modifier!::Function = (x...)->nothing, countrycode = "COD", year = 2024)
    ind = findall(in(activeage),cmt.ageinterval)
    parkeys = Symbol.(["1_" "2_"],"addmat",ind)
    [cmt.parameters[key]=fill(1.1) for key in parkeys]
    cmt.parameters[:addmat_v]=fill(30.); cmt.parameters[:addmat_w]=fill(30.)
    cmt.addmat = zero(cmt.matrix)
    cmt.misc[:modifier!] = modifier!
    cmt.misc[:pop]=popsize(cmt.ageinterval, countrycode=countrycode, year = year)
    cmt.matrix = repeat([zero(cmt.matrix) cmt.matrix./2],1,2)
    cmt
end
function addsexualcontact!(cmts::NamedTuple, activeage = 10:10:40; modifier!::Function = (x...)->nothing, countrycode = "COD", year = 2024)
    [addsexualcontact!(cmt,activeage;modifier! = modifier!, countrycode=countrycode,year=year) for cmt in cmts]
    cmts
end

## main

# ContactMatrices
immunity2015(x,cm) = x≥40 ? cm.parameters[:s_vax] : (x≥30 ? cm.parameters[:s_partvax] : (x==0 ? cm.parameters[:s_infant] : cm.parameters[:s_baseline]))
immunity2024(x,cm) = x≥50 ? cm.parameters[:s_vax] : (x≥40 ? cm.parameters[:s_partvax] : (x==0 ? cm.parameters[:s_infant] : cm.parameters[:s_baseline]))

filters = [nothing, (phys_contact=1,),(cnt_home=1,),(phys_contact=1,cnt_home=1)]
zmb2015_original = (;zip([:all, :phys, :home, :physhome] ,contactmatrix.(:zimbabwe_survey, Ref(tshuapa_h2hag), "COD", filters,year=2013,refyear=2012,refcountrycode="MAN"))...)
drc2015_original = (;zip([:all, :home] ,contactmatrix.([contact_all, contact_home], (tshuapa_h2hag), :COD, year=2013))...)
zmb2024_original = (;zip([:all, :phys, :home, :physhome] ,contactmatrix.(:zimbabwe_survey, Ref(drc_endemic_ag), "COD", filters,year=2024,refyear=2012,refcountrycode="MAN"))...)
drc2024_original = (;zip([:all, :home] ,contactmatrix.([contact_all, contact_home],Ref(drc_endemic_ag), :COD, year=2024))...)
bdi2024_original = (;zip([:all, :phys, :home, :physhome] ,contactmatrix.(:zimbabwe_survey, Ref(drc_endemic_ag), "BDIC", filters,year=2024,refyear=2012,refcountrycode="MAN"))...)
bdi_s2024_original = (;zip([:all, :home] ,contactmatrix.([contact_all, contact_home],Ref(drc_endemic_ag), :BDIC, year=2024))...)


zmb2015 = parameterise(zmb2015_original, immunity2015)
zmb2024 = parameterise(zmb2024_original, immunity2024)
bdi2024 = parameterise(bdi2024_original, immunity2024)

function propmix!(p::Pyramid,cm::ContactMatrix)#, bcond = [0.1,0.01])
    bcond = cm.misc[:bcond]
    addmatkeys = filter(Base.Fix1(occursin, "_addmat")∘string,keys(cm.parameters))
    
    ind = split.(string.(addmatkeys),Ref("_addmat")).|> (Base.BroadcastFunction(Base.Fix1(parse,Int)))
    paramat = [cm.parameters[Symbol(r,"_addmat",c)] for r in first.(ind)|>unique|>sort, c in last.(ind)|>unique|>sort].|>getindex # row-wise arrangement
    
    #modifier_ll=sum(log.(abs.(paramat.-1)))/10000 # prior adjustment
    
    paramat .= (1 .-paramat).^2 ./2 # transform for stable search
    paqa=[zeros(cm.ageinterval|>size) for x in 1:2]
    paqa_substitute=paramat|>eachrow|>collect
    for i in 1:2 paqa[i][last.(ind)|>unique|>sort].=paqa_substitute[i] end
    na=convert(Vector{Float64},cm.misc[:pop])./2
    sum_napaqa=sum.(broadcast.(*, Ref(na), paqa))

    modifier_ll = -sum(((log.(sum_napaqa./[sum(na[4:7]),1]).-log.(bcond))./log.(bcond)).^2) # penalty term to ensure boundary condition

    # Rescale to ensure high risk pop size is as specified
    paqa.*=[sum(na[4:7]),1].*bcond./sum_napaqa 
    sum_napaqa.=sum.(broadcast.(*, Ref(na), paqa))
    #cm.misc[:paqa_denomweights]=Ref(na[4:7])./([sum(na[4:7]),1].*bcond) # save this to reproduce the rescaled parameters later by: paqa./sum(denomweights.*paqa)
    
    vw=[cm.parameters[:addmat_v][],cm.parameters[:addmat_w][]] #v/w: #partners of women / men
    v0=vw[1]/((sqrt(12^2+22^2)/(17.61+5.51))^2+1)
    w0 = v0*(sum_napaqa[2]/sum_napaqa[1])
    s_cmt = broadcast.(*,Ref(na),paqa./sum_napaqa,[[vw[1].*ones(paqa[1]|>size)] [vw[2].*ones(paqa[2]|>size)];[v0.*paqa[2]] [w0.*paqa[1]]]') # [vS_MF v0S_MF; wS_FM w0S_FM]
    addmat = Matrix{Real}[fill(zero(s_cmt[1]),1,2) s_cmt[1:1,:];
        fill(zero(s_cmt[1]),1,4);
        s_cmt[2:2,:] fill(zero(s_cmt[1]),1,2) 
        fill(zero(s_cmt[1]),1,4)]
    cm.addmat=addmat|>transpose
    
    modifier_ll #-sum(((log.(sum_napaqa./[sum(na[4:7]),1]).-log.(bcond))./log.(bcond)).^2)*10000 # modifier_ll to output
end

drc2015 = parameterise(drc2015_original, immunity2015)
drc2024 = parameterise(drc2024_original, immunity2024)
bdi_s2024 = parameterise(bdi_s2024_original, immunity2024)


