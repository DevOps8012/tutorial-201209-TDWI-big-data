#!/usr/bin/env Rscript

#
# Example 2: airline
#
# Calculate average enroute times by year and market (= airport pair) from the
# airline data set (http://stat-computing.org/dataexpo/2009/the-data.html).
# Requires rmr package (https://github.com/RevolutionAnalytics/RHadoop/wiki).
#
# by Jeffrey Breen <jeffrey@jeffreybreen.com>
#

library(rmr)
# library(plyr)

# Set "LOCAL" variable to T to execute using rmr's local backend.
# Otherwise, use Hadoop (which needs to be running, correctly configured, etc.)

LOCAL=T

if (LOCAL)
{
	rmr.options.set(backend = 'local')
	
	# we have smaller extracts of the data in this project's 'local' directory
	hdfs.data.root = 'data/local/airline'
	hdfs.data = file.path(hdfs.data.root, '20040325-jfk-lax.csv')
		
	hdfs.out.root = 'out/airline'
	hdfs.out = file.path(hdfs.out.root, 'out')
	
	if (!file.exists(hdfs.out))
		dir.create(hdfs.out.root, recursive=T)
	
} else {
	rmr.options.set(backend = 'hadoop')
	
	# assumes 'airline' and airline/data exists on HDFS under user's home directory
	# (e.g., /user/cloudera/airline/ & /user/cloudera/airline/data/)
	
	hdfs.data.root = 'airline'
	hdfs.data = file.path(hdfs.data.root, 'data')

	# unless otherwise specified, directories on HDFS should be relative to user's home
	hdfs.out.root = hdfs.data.root
	hdfs.out = file.path(hdfs.out.root, 'out')
}


# asa.csvtextinputformat() - input formatter based on jseidman's cvstextinputformat
#
#  1. added field names for better code readability (esp. in mapper)
#  2. use make.input.format() to wrap our own function
#
asa.csvtextinputformat = make.input.format( format = function(con, nrecs) {

	line = readLines(con, nrecs)
	
	values = unlist( strsplit(line, "\\,") )
	
	if (!is.null(values)) {
		
		names(values) = c('Year','Month','DayofMonth','DayOfWeek','DepTime','CRSDepTime',
					  'ArrTime','CRSArrTime','UniqueCarrier','FlightNum','TailNum',
					  'ActualElapsedTime','CRSElapsedTime','AirTime','ArrDelay',
					  'DepDelay','Origin','Dest','Distance','TaxiIn','TaxiOut',
					  'Cancelled','CancellationCode','Diverted','CarrierDelay',
					  'WeatherDelay','NASDelay','SecurityDelay','LateAircraftDelay')
	
		return( keyval(NULL, values) )
	}
}, mode='text' )

#
# the mapper gets a key and a value vector generated by the formatter
# in our case, the key is NULL and all the field values come in as a vector
#
mapper.year.market.enroute_time = function(key, val) {
	
	# Skip header lines, cancellations, and diversions:
	if ( !identical(as.character(val['Year']), 'Year')
		 & identical(as.numeric(val['Cancelled']), 0)
		 & identical(as.numeric(val['Diverted']), 0) ) {		 	
		
		# We don't care about direction of travel, so construct 'market'
		# with airports ordered alphabetically
		# (e.g, LAX to JFK becomes 'JFK-LAX'
		if (val['Origin'] < val['Dest'])
			market = paste(val['Origin'], val['Dest'], sep='-')
		else
			market = paste(val['Dest'], val['Origin'], sep='-')
		
		# key consists of year, market
		output.key = c(val['Year'], market)
		
		# emit gate-to-gate elapsed times (CRS and actual) + time in air
		output.val = c(val['CRSElapsedTime'], val['ActualElapsedTime'], val['AirTime'])
		
		return( keyval(output.key, output.val) )
	}
}


#
# the reducer gets all the values for a given key
# the values (which may be mult-valued as here) come in the form of a list()
#
reducer.year.market.enroute_time = function(key, val.list) {
		
	# val.list is a list of row vectors
	# a data.frame is a list of column vectors
	# plyr's ldply() is the easiest way to convert IMHO
	if ( require(plyr) )	
		val.df = ldply(val.list, as.numeric)
	else { # this is as close as my deficient *apply skills can come w/o plyr
		val.list = lapply(val.list, as.numeric)
		val.df = data.frame( do.call(rbind, val.list) )
	}	
	colnames(val.df) = c('crs', 'actual','air')
	
	output.key = key
	output.val = c( nrow(val.df), mean(val.df$crs, na.rm=T), 
					mean(val.df$actual, na.rm=T), 
					mean(val.df$air, na.rm=T) )
	
	return( keyval(output.key, output.val) )
}


mr.year.market.enroute_time = function (input, output) {
	mapreduce(input = input,
			  output = output,
			  input.format = asa.csvtextinputformat,
			  output.format='csv', # note to self: 'csv' for data, 'text' for bug
			  map = mapper.year.market.enroute_time,
			  reduce = reducer.year.market.enroute_time,
			  backend.parameters = list( 
			  	hadoop = list(D = "mapred.reduce.tasks=2") 
			  	),
			  verbose=T)
}

out = mr.year.market.enroute_time(hdfs.data, hdfs.out)

# There seems to be a bug in 1.3.1 -- I can't seem to fetch the results 
# when running against the cluster (which is sort of a problem...)
# Let's take this opportunity to show off mapreduce's output.format
# and view results on disk with 'hadoop fs -text airline/out/part-00000 | head"

if (LOCAL)
{
	results.df = as.data.frame( from.dfs(out, structured=T) )
	colnames(results.df) = c('year', 'market', 'flights', 'scheduled', 'actual', 'in.air')

	print(head(results.df))
}


# "Big Data in, small results out" -- it's easy enough to save the results
# to disk as a native R object for later analysis:

# save(results.df, file="out/enroute.time.RData")
