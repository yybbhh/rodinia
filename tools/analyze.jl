#!/usr/bin/env julia

# include("common.jl")

function analyze(host=gethostname(), dst=nothing, suite="julia_cuda")
    measurements = CSV.read("measurements_$host.dat")
    grouped = summarize(measurements)

    # add device totals for each benchmark
    grouped_kernels = filter(entry->!startswith(entry[:target], '#'), grouped)
    grouped = vcat(grouped,
                   by(grouped_kernels, [:suite, :benchmark],
                      dt->DataFrame(target = "#device",
                                    time = sum(dt[:time]),
                                    target_iterations = missing,
                                    benchmark_iterations = allequal(dt[:benchmark_iterations]))))

    # XXX: add compilation time to host measurements
    # grouped[(grouped[:suite].==suite) .& (grouped[:target].=="#host"), :time] +=
    #     grouped[(grouped[:suite].==suite) .& (grouped[:target].=="#compilation"), :time]

    # select values for the requested suite, adding ratios against the baseline
    analysis = by(grouped, [:benchmark, :target]) do df
        baseline_data = df[df[:suite] .== baseline, :]
        suite_data = df[df[:suite] .== suite, :]

        entry_or_missing(data, col) = size(data, 1) == 1 ? data[1, col] : missing
        get_baseline(col) = entry_or_missing(baseline_data, col)
        get_suite(col) = entry_or_missing(suite_data, col)

        DataFrame(reference = get_baseline(:time), time = get_suite(:time),
                  ratio = get_suite(:time) / get_baseline(:time),
                  target_iterations = get_suite(:target_iterations),
                  benchmark_iterations = get_suite(:benchmark_iterations))
    end
    println(analysis)

    # calculate ratio grand totals
    geomean(x) = prod(x)^(1/length(x))  # ratios are normalized, so use geomean
    totals = by(filter(row->startswith(row[:target], '#'), analysis), [:target]) do df
        DataFrame(reference = sum(df[:reference]), time = sum(df[:time]),
                  ratio = geomean(df[:ratio]),
                  target_iterations = missing,
                  benchmark_iterations = missing)
    end
    totals = hcat(DataFrame(benchmark=fill("#all", size(totals,1))), totals)
    analysis = vcat(analysis, totals)

    @info "Analysis complete"
    println(filter(row->startswith(row[:target], '#'), analysis))

    # prepare measurements for PGF
    analysis[:speedup] = 1 - analysis[:ratio]
    function decompose(df)
        df = copy(df)
        for column in names(df)
            if eltype(df[column]) <: Union{Measurement, Union{Missing,<:Measurement}}
                df[Symbol("$(column)_val")] = map(datum->ismissing(datum)?missing:datum.val,
                                                        df[column])
                df[Symbol("$(column)_err")] = map(datum->ismissing(datum)?missing:datum.err,
                                                        df[column])
                delete!(df, column)
            end
        end
        return df
    end

    # per-benchmark totals
    let analysis = filter(row->!startswith(row[:benchmark], '#') && startswith(row[:target], '#'), analysis)
        # move from time and reference time for every benchmark x target,
        # to different time columns for every benchmark
        # (easier for PGF to plot)
        analysis = DataFrame(
            benchmark            = unique(analysis[:benchmark]),
            cuda_host            = analysis[analysis[:target] .== "#host",        :reference],
            cuda_device          = analysis[analysis[:target] .== "#device",      :reference],
            julia_host           = analysis[analysis[:target] .== "#host",        :time],
            julia_device         = analysis[analysis[:target] .== "#device",      :time],
            julia_compilation    = analysis[analysis[:target] .== "#compilation", :time],
            julia_kernels        = analysis[analysis[:target] .== "#compilation", :target_iterations]
        )
        sort!(analysis, cols=:julia_host)
        if dst != nothing
            CSV.write(joinpath(dst, "perf.csv"), decompose(analysis); header=true)
        end

        analysis[:julia_compilation] = analysis[:julia_compilation] ./ 1000
        @info("JIT compilation",
              data=analysis[[:benchmark, :julia_compilation, :julia_kernels]],
              mean=mean(analysis[:julia_compilation]))
    end

    # per-benchmark kernel timings
    let analysis = filter(row->!startswith(row[:benchmark], '#') && row[:target] == "#device", analysis)
        analysis = analysis[[:benchmark, :speedup]]
        sort!(analysis, cols=:speedup; rev=true)
        if dst != nothing
            CSV.write(joinpath(dst, "perf_device.csv"), decompose(analysis); header=true)
        end
    end

    # total kernel speedup
    let analysis = analysis[(analysis[:benchmark] .== "#all") .& (analysis[:target] .== "#device"), :speedup]
        if dst != nothing
            open(joinpath(dst, "perf_device_total.csv"), "w") do io
                println(io, analysis[1].val)
            end
        end
    end

    return
end
