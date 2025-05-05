import math

'''
This file contains a number of helper functions.
    - get_node_to_district(districting, nodes):This function reconstructs for a multiscale districting description
 the mapping from precinct IDs to Districts for a given map

    - sumElection(electionName, node_to_dist,  data): This function sums a particular election, given in electionName, of a set of election data and 
    a node_to_dist map.

    - stateWideVotes(electionName,dataElection): this returns the democratic, republican and total votes 
    summered across the entire state using the votes in stateWideVotes.

    - addUniformSwings(targetDemFractions,electionNames,dataElection): given a particular set of election data (given in dataElection)
    this swings the election, given in electionNames, so the democratic vote fraction is equal to targetDemFractions

    - listElections(dataElection): this returns a list of the names of the elections contained in
     dataElection

    - addTotalVotes(dataElection): sometimes the data is missing the vote totals (given by the suffix "_T"), having only the 
    democratic (given by the suffix "_D") and the republican (given by the suffix "_R"). This 
    function added the total vote entry if it is missing and does nothing if it is exist.

    - demWinByPrecicts(elections,node_to_dist,dataElection): this returns the predicts in which the democrats won
    using the votes in  elections and the node_to_dist map.

    There are also a number of functions to calculate statistics of
    histograms such as: histMode,histNormalize,histSpread,histMedean, histStd, histMean .

'''

def get_node_to_district(districting, nodes):
    # This function reconstructs for a multiscale districting description
    # the mapping from precinct IDs to Districts for a given map 
    node_id_to_district = {}
    for node in nodes:
        county = node["county"]
        cnty_key = '[\"'+county+'\"]'
        if cnty_key in districting:
            node_id_to_district[node["id"]] = districting[cnty_key]
            continue
        pct = node["prec_id"]
        cnty_pct_key = '[\"'+county+'\", \"' + pct + '\"]'
        if cnty_pct_key in districting:
            node_id_to_district[node["id"]] = districting[cnty_pct_key]
        else:
            print(node, county, pct, cnty_key, cnty_pct_key)
    return node_id_to_district


def sumElection(electionName, node_to_dist,  data):
    # This function sums a particular election, given in electionName, of a set of election data and 
    # a node_to_dist map.
    distVoteR = {}
    distVoteD = {}
    distVoteT = {}
    for id in node_to_dist.keys():
        d = node_to_dist[id]
        if d in distVoteT.keys():
            distVoteR[d] += data[id][electionName+"_R"]
            distVoteD[d] += data[id][electionName+"_D"]
            distVoteT[d] += data[id][electionName+"_T"]
        else:
            distVoteR[d] = data[id][electionName+"_R"]
            distVoteD[d] = data[id][electionName+"_D"]
            distVoteT[d] = data[id][electionName+"_T"]
    return distVoteR, distVoteD, distVoteT

def stateWideVotes(electionName,dataElection):
    votes={}
    votes["Total"]=sum([ p[electionName+'_T'] for  p in dataElection])
    votes["Rep"]=sum([ p[electionName+'_R'] for  p in dataElection])
    votes["Dem"]=sum([ p[electionName+'_D'] for  p in dataElection])
    return votes


def addUniformSwings(targetDemFractions,electionNames,dataElection):
    for electionName in electionNames:
        votes=stateWideVotes(electionName,dataElection)
        stateWideVoteFraction=votes["Dem"]/votes["Total"]
        for targetDemFraction  in targetDemFractions:
            for p in dataElection:
                p[electionName+'_USF'+str(targetDemFraction)+'_D']=p[electionName+'_D']*targetDemFraction/stateWideVoteFraction
                p[electionName+'_USF'+str(targetDemFraction)+'_R']=p[electionName+'_R']*(1.0-targetDemFraction)/(1.0-stateWideVoteFraction)
                p[electionName+'_USF'+str(targetDemFraction)+'_T']=p[electionName+'_T']


def listElections(dataElection, prefix="G", exluded={'id','prec_id','pop2020cen','MCD','area','border_length'},idx=0):
    return [ e[0:-2] for e in dataElection[idx].keys() if e not in {'id','prec_id','pop2020cen','MCD','area','border_length'} and e[-1] == 'D']

def addTotalVotes(dataElection):
    elections=listElections(dataElection)
    for e in elections:
        if (e+"_T" not in dataElection[0].keys()):
            for p in dataElection:
                p[e+"_T"]=p[e+"_D"]+p[e+"_R"]
        
import numpy as np

def demWinByPrecicts(elections,node_to_dist,dataElection):
    numDemsPrecinct=np.zeros(len(node_to_dist.keys()))
    for e in elections:
        distVoteR, distVoteD, distVoteT = sumElection(e, node_to_dist,
                                                            dataElection)
        for id in node_to_dist.keys():
            # id = 100
            # print(e, id, count, distVoteD[node_to_dist[id]], distVoteR[node_to_dist[id]])
            if distVoteD[node_to_dist[id]] >distVoteR[node_to_dist[id]]:
                numDemsPrecinct[id]+=1
    return numDemsPrecinct

def histMode(hist):
    return max(hist, key=hist.get)

def histNormalize(hist):
    total=sum(hist.values())
    histNorm={}
    for k in hist.keys():
        histNorm[k]=hist[k]/total
    return histNorm

def histMean(hist):
    mn=0.0
    total=sum(hist.values())
    for k in hist.keys():
       mn+=k*hist[k]
    mn=mn/total
    return mn

def histStd(hist,scale=1.0):
    mn=histMean(hist)
    std=0.0
    total=sum(hist.values())
    for k in hist.keys():
       std+=((k-mn)**2)*hist[k]
    std=std/total
    return math.sqrt(std)/scale

def histMedean(hist):
    totalMass=sum(hist.values())
    keys=(list(hist.keys()))
    keys.sort()
    mass=0.0
    lastMass=0.0
    kLast=0.0
    for k in keys:
        mass+=hist[k]
        if mass >= totalMass/2.0:
            break
        kLast=k
        lastMass=mass
    if kLast>0.0:
        d=k-kLast
        a=(totalMass/2.0-lastMass)/(mass-lastMass)
        return  (a*kLast + (1.0-a)*k)
    else:
        d=k
        a=(totalMass/2.0)/mass
        return  (1.0-a)*k

def histSpread(hist,scale=1.0):
    l=list(hist.keys())
    return (max(l)-min(l))/scale

