#!/bin/bash

#This is a command run by a crontab that wraps the actual function you actually want to run.


##Needed for cron jobs where the job will be started in the home directory, so gives us an option to move to a new directory.

if [[ $# -gt 0 ]]
  then cd "${1}"  
fi

source environment_variables.sh

executable_to_run="sbatch --parsable "
run_script="run_job.sh"
cleanup_script="cleanup.sh"

count=0

write_log "Starting cron.target.sh in directory $(pwd)"

#Look to the bottom of the loop for defn of UoW
#Expecting copy operations for RELION to take longer than the period of the cron job, so adding a sentinel whilst
#copying to the slurm directory for analysis. This should really me broken

echo "Search for directories to analyse"
while read UoW; do
    if [[ -n "${UoW}" ]]; then #test for an empty value. This is given if findPossible... looks at an empty dir.
      #define variables
      short_filename=${UoW##*/}
      #slurm_filename="${short_filename}_slurm.sh"
      timestamp=$(date '+%Y%m%d-%H%M%S')

      #RFI's Globus script will add the timestamp to the directory so they know what it's called.
      #work_dir="slurm/${short_filename}-${timestamp}"
      work_dir="slurm/${short_filename}"

      #Create workdir; skip to next if this fails.
      write_log "Creating ${work_dir}"
#      mkdir -p ${work_dir} || (write_log "Failed to create dir ${work_dir}" && continue)

      #Move UoW to the workdir
      write_log "Running mv ${UoW} $work_dir"

      #A sentinel file should stop findPossibleUnitsOfWork picking it up again and trying to move it, if it's not finished by the
      #time of the next cron run 
      copy_sentinel_files="transfer_to_slurm-${timestamp}"
      write_log "Writing sentinel ${UoW}/sentinels/${copy_sentinel_files} to prevent multiple copies"
      touch "${UoW}/sentinels/${copy_sentinel_files}"
      mv "$UoW" "$work_dir"
      write_log "mv $UoW $work_dir complete. Removing sentinel ${work_dir}/sentinels/${copy_sentinel_files}."
      rm "${work_dir}/sentinels/${copy_sentinel_files}"

      #Increment count of files ran
      count=$((count+1))

      #this means we can never copy to the same directory in slurm/ due to changing the time.
      sleep 1
    fi
done <<< $(findPossibleUnitsOfWorkSentinelCreatedByGlobus "${holding_area}")
write_log "Complete; moved ${count} Units of work to slurm/."

#Reusing findPossibleUnitsOfWork but targeting the slurm/ directory.
count=0
while read UoW_slurm; do
  if [[ -n "${UoW_slurm}" ]]; then #test for an empty value. This is given if findPossible... looks at an empty dir.
    #Customise slurm file
    path_to_slurm_file="${UoW_slurm}/scripts/submission_script.sh"
    sed -i "s#SUBST#${UoW_slurm}/slurm#g"  "${path_to_slurm_file}"

    #Start analysis
    write_log "Starting analysing ${filename}"
    write_log "${executable_to_run} ${path_to_slurm_file}"

    job_id=$(${executable_to_run} "${path_to_slurm_file}"  "${UoW_slurm}")

    if [ $? -ne 0 ]; then
      write_log "FAILED when running slurm script; bypassing cleanup and moving ${UoW_slurm} directory"	
      mv "${UoW_slurm}" ${failed_area}	
      continue
    fi

    #Create a sentinel to prevent it being analysed multiple times
    touch "${UoW_slurm}/sentinels/SlurmRunning-${job_id}"
    
    #Copy to a destination based on existence of a slurm stats file and it containing "Exitcode 0:0"
    write_log "cron.target sent ${executable_to_run} ${path_to_slurm_file} ${UoW_slurm} with JobID ${job_id} to the queue"
    cleanup_job_id=$(sbatch --dependency afterany:${job_id} --parsable ${cleanup_script} ${UoW_slurm} ${job_id})
    write_log "clean_up created with ${cleanup_job_id} to the queue"

    #Increment count of files ran
    count=$((count+1))
  fi
done <<< $(findPossibleUnitsOfWork "slurm")

write_log "Complete; analysed ${count} files."