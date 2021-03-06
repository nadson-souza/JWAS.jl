#return column index for each level of variables in incidence matrix X
#e.g. "A1"=>1,"A2"=>2
function mkDict(a)
  aUnique = unique(a)
  d = Dict()
  names = Array{Any}(size(aUnique,1))
  for (i,s) in enumerate(aUnique)
    names[i] = s
    d[s] = i
  end
  return d,names
end

"""
    build_model(model_equations::AbstractString,R;df::Float64=4.0)

* Build models from **model equations** with residual varainces **R** and degree
  of freedom for residual variance **df** defaulting to 4.0.
* By default, all variabels in model_equations are fixed and factors. Set variables
  to be covariates or random using functions `set_covariate()` or `set_random()`.

```julia
#single-trait
model_equations = "BW = intercept + age + sex"
R               = 6.72
models          = build_model(model_equations,R);

#multi-trait
model_equations = "BW = intercept + age + sex;
                   CW = intercept + litter";
R               = [6.72   24.84
                   24.84  708.41]
models          = build_model(model_equations,R);
```
"""
function build_model(model_equations::AbstractString,R;df=4)
  if !(typeof(model_equations)<:AbstractString) || model_equations==""
      error("Model equations are wrong.\n
      To find an example, type ?build_model and press enter.\n")
  end

  modelVec   = [strip(i) for i in split(model_equations,[';','\n'],keep=false)]
  nModels    = size(modelVec,1)
  lhsVec     = Symbol[]    #:y, phenotypes
  modelTerms = ModelTerm[] #initialization outside for loop
  dict       = Dict{AbstractString,ModelTerm}()
  for (m,model) = enumerate(modelVec)
    lhsRhs = split(model,"=")                  #"y2","A+B+A*B"
    lhsVec = [lhsVec;Symbol(strip(lhsRhs[1]))] #:y2
    rhsVec = split(strip(lhsRhs[2]),"+")       #"A","B","A*B"
    mTrms  = [ModelTerm(strip(trmStr),m) for trmStr in rhsVec]
    modelTerms  = [modelTerms;mTrms]           #vector of ModelTerm
  end
  for (i,trm) = enumerate(modelTerms)          #make a dict for model terms
    dict[trm.trmStr] = modelTerms[i]
  end
  return MME(nModels,modelVec,modelTerms,dict,lhsVec,map(Float64,R),Float64(df))
end

"""
    set_covariate(mme::MME,variables::AbstractString...)

* set **variables** as covariates; **mme** is the output of function `build_model()`.

```julia
#After running build_model, variabels age and year can be set to be covariates as
set_covariate(models,"age","year")
#or
set_covariate(models,"age year")
```
"""
function set_covariate(mme::MME,covStr::AbstractString...)
  covVec=[]
  for i in covStr
    covVec = [covVec;split(i," ",keep=false)]
  end
  mme.covVec = [mme.covVec;[Symbol(i) for i in covVec]]
end

################################################################################
#Get all data from data files (in DataFrame) based on each ModelTerm
#Fill up str and val for each ModelTerm
################################################################################

function getData(trm::ModelTerm,df::DataFrame,mme::MME) #ModelTerm("1:A*B")
  nObs    = size(df,1)
  trm.str = Array{AbstractString}(nObs)
  trm.val = Array{Float64}(nObs)

  if trm.factors[1] == :intercept #for intercept
    str = fill("intercept",nObs)
    val = fill(1.0,nObs)
  else                            #for ModelTerm e.g. "1:A*B" (or "1:A")
    myDf = df[trm.factors]                          #:A,:B
    if trm.factors[1] in mme.covVec                 #if A is a covariate
      str = fill(string(trm.factors[1]),nObs)       #["A","A",...]
      val = df[trm.factors[1]]                      #df[:A]
    else                                            #if A is a factor (animal or maternal effects)
      str = [string(i) for i in df[trm.factors[1]]] #["A1","A3","A2","A3",...]
      val = fill(1.0,nObs)
    end

    #for ModelTerm object e.g. "A*B" whose nFactors>1
    for i=2:trm.nFactors
      if trm.factors[i] in mme.covVec
        #["A * B","A * B",...] or ["A1 * B","A2 * B",...]
        str = str .* fill(" * "*string(trm.factors[i]),nObs)
        val = val .* df[trm.factors[i]]
      else
        #["A * B1","A * B2",...] or ["A1 * B1","A2 * B2",...]
        str = str .* fill(" * ",nObs) .* [string(j) for j in df[trm.factors[i]]]
        val = val .* fill(1.0,nObs)
      end
    end
  end
  trm.str = str
  trm.val = val
end

#getFactor1(str) = [strip(i) for i in split(str,"*")][1] #Bug:only for animal*age, not age*animal
getFactor(str) = [strip(i) for i in split(str,"*")]

################################################################################
# make incidence matrix for each ModelTerm
#
################################################################################
function getX(trm::ModelTerm,mme::MME)
    #Row Index
    nObs  = length(trm.str)
    xi    = (trm.iModel-1)*nObs + collect(1:nObs)
    #Value
    xv    = trm.val
    #Column Index
    if trm.trmStr in mme.pedTrmVec
       #########################################################################
       #random polygenic effects,e.g."Animal","Animal*age"
       #column index needs to compromise numerator relationship matrix
       #########################################################################
       trm.names   = PedModule.getIDs(mme.ped)
       trm.nLevels = length(mme.ped.idMap)
       whichobs    = 1

       xj          = []
       for i in trm.str
         for animalstr in getFactor(i) #two ways:animal*age;age*animal
           if haskey(mme.ped.idMap, animalstr)   #"animal" ID not "age"
             xj = [xj; mme.ped.idMap[animalstr].seqID]
           elseif animalstr=="0" #founders "0" are not effects (fitting maternal effects)
                                 #all non-founder animals in pedigree are effects
             xj = [xj; 1]        #put 1<=any interger<=nAnimal is okay)
             xv[whichobs]=0      #thus add one row of zeros in X
           end
           whichobs    += 1
         end
       end
       xj        = round.(Int64,xj)

       #some animal IDs in pedigree may be missing in data (df),ensure #columns = #animals in
       #pedigree by adding a column of zeros
       pedSize = length(mme.ped.idMap)
       xi      = [xi;1]          # adding a zero to
       xj      = [xj;pedSize]    # the last column in row 1
       xv      = [xv;0.0]
    else
       #########################################################################
       #other fixed or random effects
       #########################################################################
       dict,trm.names  = mkDict(trm.str) #key: levels of variable; value: column index
       trm.nLevels     = length(dict)
       xj              = round.(Int64,[dict[i] for i in trm.str]) #column index
    end

    trm.X = sparse(xi,xj,xv)
    trm.startPos = mme.mmePos
    mme.mmePos  += trm.nLevels
end

"""
Construct mixed model equations with

incidence matrix: X      ;
response        : ySparse;
left-hand side  : mmeLhs ;
right-hand side : mmeLhs ;
"""
function getMME(mme::MME, df::DataFrame)
    if mme.mmePos != 1
      error("Please build your model again using the function build_model().")
    end

    #Make incidence matrices X for each term
    for trm in mme.modelTerms
      getData(trm,df,mme)
      getX(trm,mme)
    end
    #concatenate all terms
    X   = mme.modelTerms[1].X
    for i=2:length(mme.modelTerms)
       X = [X mme.modelTerms[i].X]
    end

    #Make response vector (y)
    y = convert(Array,df[mme.lhsVec[1]],0.0) #convert NA to zero
    for i=2:size(mme.lhsVec,1)
      y   = [y; convert(Array,df[mme.lhsVec[i]],0.0)]
    end
    ii    = 1:length(y)
    jj    = ones(ii)
    vv    = y
    ySparse = sparse(ii,jj,vv)

    #Make lhs and rhs for MME
    mme.X       = X
    mme.ySparse = ySparse

    if mme.nModels==1     #single-trait (lambda version)
      mme.mmeLhs = X'X
      mme.mmeRhs = X'ySparse
    elseif mme.nModels>1  #multi-trait
      Ri         = mkRi(mme,df) #handle missing phenotypes with ResVar
                                #make MME without variance estimation (constant)
                                #and residual imputation
      mme.mmeLhs = X'Ri*X
      mme.mmeRhs = X'Ri*ySparse
    end

    #Random effects parts in MME
    #Pedigree
    if mme.ped != 0
      ii,jj,vv = PedModule.HAi(mme.ped)
      HAi = sparse(ii,jj,vv)
      mme.Ai = HAi'HAi
      addA(mme::MME)
    end

    #iid random effects,NEED another addlambda for multi-trait
    if mme.nModels==1 #single-trait
      addLambdas(mme)
    end
end

#more details later
function getinfo(model)
  println("A Mixed Effects Model was build with")
  println("Model equations:")
  for i in models.modelVec
    println(i)
  end
  println("Term","\t\t","Covariate","\t\t","Factor","\t","Fixed","\t","Random")
  for i in models.modelTerms
    println(i.trmStr,"\t\t",10,"\t\t",10)
  end
  #incidence matrix , #elements non-zero elements
  #"incomplete or complete",genomic data
end
