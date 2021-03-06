function MT_MCMC_BayesC(nIter,mme,df;
                      Pi      =0.0,
                      sol     =false,
                      outFreq =1000,
                      estimatePi         =false,
                      missing_phenotypes =false,
                      constraint         =false,
                      methods            ="conventional analyses",
                      output_samples_frequency=0,
                      update_priors_frequency=0,
                      MCMC_marker_effects_file="MCMC_samples_for_marker_effects.txt")

    ############################################################################
    # Pre-Check
    ############################################################################
    #starting values for location parameters(no marker) are sol
    sol,solMean = pre_check(mme,df,sol)
    if mme.M !=0
      if methods == "BayesC"
        if Pi == 0.0
          error("Pi (Π) is not provided!!")
          #println("Same values are used for Πi.")
        end
        BigPi = copy(Pi)
        BigPiMean = copy(Pi)
        for key in keys(BigPiMean)
          BigPiMean[key]=0.0
        end
      elseif methods == "BayesCC"
        if Pi == 0.0
          error("Pi is not provided!!")
          #println("Same values are used for Πi.")
        end
        #label with the index of Array
        #labels[1]=[0.0,0.0],labels[2]=[1.0,1.0]
        #BigPi[1]=0.3,BigPi[2]=0.7
        nlabels= length(Pi)
        labels = Array(Array{Float64,1},nlabels)
        BigPi  = Array(Float64,nlabels)
        whichlabel=1
        for pair in sort(collect(Pi), by=x->x[2],rev=true)
          key=pair[1]
          labels[whichlabel]=copy(key)
          BigPi[whichlabel]=copy(pair[2])
          whichlabel = whichlabel+1
        end
        BigPiMean = zeros(BigPi)
      elseif methods == "BayesC0" && estimatePi==true
        error("Estimating π is not allowed in BayesC0")
      end
    end
    ############################################################################
    # PRIORS
    ############################################################################
    #Priors for residual covariance matrix
    ν       = mme.df.residual
    nObs    = size(df,1)
    nTraits = size(mme.lhsVec,1)
    νR0     = ν + nTraits
    R0      = mme.R
    PRes    = R0*(νR0 - nTraits - 1)
    SRes    = zeros(Float64,nTraits,nTraits)
    R0Mean  = zeros(Float64,nTraits,nTraits)
    scaleRes= diag(mme.R)*(ν-2)/ν #only for chisq for constraint diagonal R

    #Priors for polygenic effect covariance matrix
    if mme.ped != 0
      ν         = mme.df.polygenic
      pedTrmVec = mme.pedTrmVec
      k         = size(pedTrmVec,1)
      νG0       = ν + k
      G0        = inv(mme.Gi)
      P         = G0*(νG0 - k - 1)
      S         = zeros(Float64,k,k)
      G0Mean    = zeros(Float64,k,k)
    end

    ##SET UP MARKER PART
    if mme.M != 0
        ########################################################################
        #Priors for marker covaraince matrix
        ########################################################################
        mGibbs      = GibbsMats(mme.M.genotypes)
        nObs,nMarkers,mArray,mpm,M = mGibbs.nrows,mGibbs.ncols,mGibbs.xArray,mGibbs.xpx,mGibbs.X
        dfEffectVar = mme.df.marker
        vEff        = mme.M.G
        νGM         = dfEffectVar + nTraits
        PM          = vEff*(νGM - nTraits - 1)
        SM          = zeros(Float64,nTraits,nTraits)
        GMMean      = zeros(Float64,nTraits,nTraits)
        ########################################################################
        ##WORKING VECTORS
        ########################################################################
        ycorr          = vec(full(mme.ySparse)) #ycorr for different traits
        wArray         = Array(Array{Float64,1},nTraits)#wArray is list reference of ycor
        ########################################################################
        #Arrays to save solutions for marker effects
        ########################################################################
        #starting values for marker effects(zeros) and location parameters (sol)
        alphaArray     = Array(Array{Float64,1},nTraits) #BayesC,BayesC0
        meanAlphaArray = Array(Array{Float64,1},nTraits) #BayesC,BayesC0
        deltaArray     = Array(Array{Float64,1},nTraits) #BayesC
        meanDeltaArray = Array(Array{Float64,1},nTraits) #BayesC
        uArray         = Array(Array{Float64,1},nTraits) #BayesC
        meanuArray     = Array(Array{Float64,1},nTraits) #BayesC

        for traiti = 1:nTraits
            startPosi              = (traiti-1)*nObs  + 1
            ptr                    = pointer(ycorr,startPosi)
            #wArray[traiti]         = pointer_to_array(ptr,nObs)
            wArray[traiti]         = unsafe_wrap(Array,ptr,nObs)

            alphaArray[traiti]     = zeros(nMarkers)
            meanAlphaArray[traiti] = zeros(nMarkers)
            deltaArray[traiti]     = zeros(nMarkers)
            meanDeltaArray[traiti] = zeros(nMarkers)
            uArray[traiti]         = zeros(nMarkers)
            meanuArray[traiti]     = zeros(nMarkers)
        end
    end


    ############################################################################
    # SET UP OUTPUT
    ############################################################################
    if output_samples_frequency != 0
      #initialize arrays to save MCMC samples
      num_samples = Int(floor(nIter/output_samples_frequency))
      init_sample_arrays(mme,num_samples)

      if mme.M != 0 #write samples for marker effects to a txt file
        outfile = Array{IOStream}(nTraits)
        for traiti in 1:nTraits

          file_name=MCMC_marker_effects_file*"_"*string(mme.lhsVec[traiti])*".txt"

          if isfile(file_name)
            warn("The file "*file_name*" already exists!!! It was overwritten by the new output.")
          else
            info("The file "*file_name*" was created to save MCMC samples for marker effects.")
          end

          outfile[traiti]=open(file_name,"w")
          if mme.M.markerID[1]!="NA"
              writedlm(outfile[traiti],transubstrarr(mme.M.markerID))
          end
        end
      end
      out_i = 1
    end

    ############################################################################
    #MCMC
    ############################################################################
    @showprogress "running MCMC for "*methods*"..." for iter=1:nIter
        ########################################################################
        # 1.1. Non-Marker Location Parameters
        ########################################################################
        Gibbs(mme.mmeLhs,sol,mme.mmeRhs)
        solMean += (sol - solMean)/iter

        ########################################################################
        # 1.2 Marker Effects
        ########################################################################
        if mme.M != 0
          ycorr[:] = ycorr[:] - mme.X*sol
          iR0,iGM = inv(mme.R),inv(mme.M.G)

          if methods == "BayesC"
            sampleMarkerEffectsBayesC!(mArray,mpm,wArray,
                                      alphaArray,meanAlphaArray,
                                      deltaArray,meanDeltaArray,
                                      uArray,meanuArray,
                                      iR0,iGM,iter,BigPi)
          elseif methods == "BayesC0"
            sampleMarkerEffects!(mArray,mpm,wArray,alphaArray,
                               meanAlphaArray,iR0,iGM,iter)
          elseif methods == "BayesCC"
            sampleMarkerEffectsBayesCC!(mArray,mpm,wArray,
                                        alphaArray,meanAlphaArray,
                                        deltaArray,meanDeltaArray,
                                        uArray,meanuArray,
                                        iR0,iGM,iter,BigPi,labels)
          end

          if estimatePi == true
            if methods == "BayesC"
              samplePi(deltaArray,BigPi,BigPiMean,iter)
            elseif methods == "BayesCC"
              samplePi(deltaArray,BigPi,BigPiMean,iter,labels)
            end
          end
        end


        ########################################################################
        # 2.1 Residual Covariance Matrix
        ########################################################################
        resVec = (mme.M==0?(mme.ySparse - mme.X*sol):ycorr)
        #here resVec is alias for ycor ***

        if missing_phenotypes==true
          sampleMissingResiduals(mme,resVec)
        end

        for traiti = 1:nTraits
            startPosi = (traiti-1)*nObs + 1
            endPosi   = startPosi + nObs - 1
            for traitj = traiti:nTraits
                startPosj = (traitj-1)*nObs + 1
                endPosj   = startPosj + nObs - 1
                SRes[traiti,traitj] = (resVec[startPosi:endPosi]'resVec[startPosj:endPosj])[1,1]
                SRes[traitj,traiti] = SRes[traiti,traitj]
            end
        end


        R0      = rand(InverseWishart(νR0 + nObs, convert(Array,Symmetric(PRes + SRes))))

        #for constraint R, chisq
        if constraint == true
          R0 = zeros(nTraits,nTraits)
          for traiti = 1:nTraits
            R0[traiti,traiti]= (SRes[traiti,traiti]+ν*scaleRes[traiti])/rand(Chisq(nObs+ν))
          end
        end

        if mme.M != 0
          mme.R = R0
          R0    = mme.R
          Ri    = kron(inv(R0),speye(nObs))

          RiNotUsing   = mkRi(mme,df) #get small Ri (Resvar) used in imputation
        end

        if mme.M == 0
          mme.R = R0
          Ri  = mkRi(mme,df) #for missing value;updata mme.ResVar
        end
        R0Mean  += (R0  - R0Mean )/iter

        ########################################################################
        # -- LHS and RHS for conventional MME (No Markers)
        # -- Position: between new Ri and new Ai
        ########################################################################
        X          = mme.X
        mme.mmeLhs = X'Ri*X
        if mme.M != 0
          ycorr[:]   = ycorr[:] + X*sol
          #same to ycorr[:]=resVec+X*sol
        end
        mme.mmeRhs = (mme.M == 0?(X'Ri*mme.ySparse):(X'Ri*ycorr))

        ########################################################################
        # 2.2 Genetic Covariance Matrix (Polygenic Effects)
        ########################################################################
        if mme.ped != 0  #optimize taking advantage of symmetry
            for (i,trmi) = enumerate(pedTrmVec)
                pedTrmi   = mme.modelTermDict[trmi]
                startPosi = pedTrmi.startPos
                endPosi   = startPosi + pedTrmi.nLevels - 1
                for (j,trmj) = enumerate(pedTrmVec)
                    pedTrmj    = mme.modelTermDict[trmj]
                    startPosj  = pedTrmj.startPos
                    endPosj    = startPosj + pedTrmj.nLevels - 1
                    S[i,j]     = (sol[startPosi:endPosi]'*mme.Ai*sol[startPosj:endPosj])[1,1]
                end
            end
            pedTrm1 = mme.modelTermDict[pedTrmVec[1]]
            q = pedTrm1.nLevels
            #println(P+S)
            #println(νG0 + q)

            G0 = rand(InverseWishart(νG0 + q, convert(Array,Symmetric(P + S))))
            mme.Gi = inv(G0)
            addA(mme)

            G0Mean  += (G0  - G0Mean )/iter
        end

        ########################################################################
        # 2.3 Marker Covariance Matrix
        ########################################################################

        if mme.M != 0
          for traiti = 1:nTraits
              for traitj = traiti:nTraits
                  SM[traiti,traitj]   = (alphaArray[traiti]'alphaArray[traitj])[1]
                  SM[traitj,traiti]   = SM[traiti,traitj]
              end
          end
          mme.M.G = rand(InverseWishart(νGM + nMarkers, convert(Array,Symmetric(PM + SM))))
          GMMean  += (mme.M.G  - GMMean)/iter
        end

        ########################################################################
        # 2.4 Update priors using posteriors (empirical)
        ########################################################################
        if update_priors_frequency !=0 && iter%update_priors_frequency==0
            if mme.M!=0
                PM = GMMean*(νGM - nTraits - 1)
            end
            if mme.ped != 0
                P  = G0Mean*(νG0 - k - 1)
            end
            PRes    = R0Mean*(νR0 - nTraits - 1)
            println("\n Update priors from posteriors.")
        end

        ########################################################################
        # OUTPUT
        ########################################################################
        if output_samples_frequency != 0
          if iter%output_samples_frequency==0
            outputSamples(mme,sol,out_i)
            mme.samples4R[:,out_i]=vec(R0)
            if mme.ped != 0
              mme.samples4G[:,out_i]=vec(G0)
            end
            out_i +=1
            if mme.M != 0
              for traiti in 1:nTraits
                if methods == "BayesC" || methods=="BayesCC"
                  writedlm(outfile[traiti],uArray[traiti]')
                elseif methods == "BayesC0"
                  writedlm(outfile[traiti],alphaArray[traiti]')
                end
              end
            end
          end
        end

        if iter%outFreq==0
            println("\nPosterior means at iteration: ",iter)
            println("Residual covariance matrix: \n",round.(R0Mean,6))

            if mme.ped !=0
              println("Polygenic effects covariance matrix \n",round.(G0Mean,6))
            end

            if mme.M != 0
              println("Marker effects covariance matrix: \n",round.(GMMean,6))
              if methods=="BayesC" && estimatePi == true
                println("π: \n",BigPiMean)
              elseif methods=="BayesCC" && estimatePi == true
                println("π for ", labels)
                println(round.(BigPiMean,3))
              end
            end
            println()
        end
    end

    ############################################################################
    # After MCMC
    ############################################################################
    output = Dict()

    #OUTPUT Conventional Effects
    output["Posterior mean of location parameters"]    = [getNames(mme) solMean]
    output["Posterior mean of residual covariance matrix"]       = R0Mean
    if output_samples_frequency != 0
      output["MCMC samples for residual covariance matrix"]= mme.samples4R

      for i in  mme.outputSamplesVec
          trmi   = i.term
          trmStr = trmi.trmStr
          output["MCMC samples for: "*trmStr] = [getNames(trmi) i.sampleArray]
      end
      for i in  mme.rndTrmVec
          trmi   = i.term
          trmStr = trmi.trmStr
          output["MCMC samples for: variance of "*trmStr] = i.sampleArray
      end
    end

    #OUTPUT Polygetic Effects
    if mme.ped != 0
      output["Posterior mean of polygenic effects covariance matrix"] = G0Mean
      if output_samples_frequency != 0
        output["MCMC samples for polygenic effects covariance matrix"] = mme.samples4G
      end
    end

    #OUTPUT Marker Effects
    if mme.M != 0
      if output_samples_frequency != 0  #write samples for marker effects to a txt file
        for traiti in 1:nTraits
          close(outfile[traiti])
        end
      end

      if mme.M.markerID[1]!="NA"
        markerout        = []
        if methods == "BayesC"||methods=="BayesCC"
          for markerArray in meanuArray
            push!(markerout,[mme.M.markerID markerArray])
          end
        elseif methods == "BayesC0"
          for markerArray in meanAlphaArray
            push!(markerout,[mme.M.markerID markerArray])
          end
        end
      else
        if methods == "BayesC"||methods=="BayesCC"
          markerout        = meanuArray
        elseif methods == "BayesC0"
          markerout        = meanAlphaArray
        end
      end

      output["Posterior mean of marker effects"] = markerout
      output["Posterior mean of marker effects covariance matrix"] = GMMean

      if methods=="BayesC"||methods=="BayesCC"
        output["Model frequency"] = meanDeltaArray
      end

      if estimatePi == true
        output["Posterior mean of Pi"] = BigPiMean
      end
    end

    return output
end
