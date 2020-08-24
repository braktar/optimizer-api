# Copyright © Mapotempo, 2020
#
# This file is part of Mapotempo.
#
# Mapotempo is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Mapotempo is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Mapotempo. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#
require 'grape'
require 'grape-swagger'

module Api
  module V01
    class Jobs < APIBase
      resource :jobs do # rubocop:disable Metrics/BlockLength
        desc 'Fetch vrp job status', {
          nickname: 'get_job',
          success: VrpResult,
          failure: [
            { code: 404, message: 'Not Found', model: ::Api::V01::Status }
          ],
          security: [{
            api_key_query_param: []
          }],
          detail: 'Get the job status and details, contains progress avancement. Return the best actual solutions currently found.'
        }
        params {
          requires :id, type: String, desc: 'Job id returned by creating VRP problem.'
        }
        get ':id' do # rubocop:disable Metrics/BlockLength
          id = params[:id]
          job = Resque::Plugins::Status::Hash.get(id)
          stored_result = APIBase.dump_vrp_dir.read([id, params[:api_key], 'solution'].join('_'))
          solution = stored_result && Marshal.load(stored_result)

          if solution.nil? && (job.nil? || job.killed? || Resque::Plugins::Status::Hash.should_kill?(id) || job['options']['api_key'] != params[:api_key])
            status 404
            error!({ status: 'Not Found', message: "Job with id='#{id}' not found" }, 404)
          end

          solution ||= OptimizerWrapper::Result.get(id) || {}
          output_format = params[:format]&.to_sym || ((solution && solution['csv']) ? :csv : env['api.format'])
          env['api.format'] = output_format # To override json default format

          if job&.completed? # job can still be nil if we have the solution from the dump
            OptimizerWrapper.job_remove(params[:api_key], id)
            APIBase.dump_vrp_dir.write([id, params[:api_key], 'solution'].join('_'), Marshal.dump(solution)) if stored_result.nil? && OptimizerWrapper.config[:dump][:solution]
          end

          status 200

          if output_format == :csv && job&.completed?
            present(OptimizerWrapper.build_csv(solution['result']), type: CSV)
          else
            present({
              solutions: [solution['result']].flatten(1),
              job: {
                id: id,
                status: job&.status&.to_sym || :completed, # :queued, :working, :completed, :failed
                avancement: job&.message,
                graph: solution['graph']
              }
            }, with: Grape::Presenters::Presenter)
          end
        end

        desc 'List vrp jobs', {
          nickname: 'get_job_list',
          success: VrpJobsList,
          detail: 'List running or queued jobs.'
        }
        get do
          status 200
          present OptimizerWrapper.job_list(params[:api_key]), with: Grape::Presenters::Presenter
        end

        desc 'Delete vrp job', {
          nickname: 'deleteJob',
          success: { code: 204 },
          failure: [
            { code: 404, message: 'Not Found', model: ::Api::V01::Status }
          ],
          detail: 'Kill the job. This operation may have delay, since if the job is working it will be killed during the next iteration.'
        }
        params {
          requires :id, type: String, desc: 'Job id returned by creating VRP problem.'
        }
        delete ':id' do # rubocop:disable Metrics/BlockLength
          id = params[:id]
          job = Resque::Plugins::Status::Hash.get(id)

          if !job || job.killed? || Resque::Plugins::Status::Hash.should_kill?(id) || job['options']['api_key'] != params[:api_key]
            status 404
            error!({ status: 'Not Found', message: "Job with id='#{id}' not found" }, 404)
          else
            OptimizerWrapper.job_kill(params[:api_key], id)
            job.status = 'killed'
            solution = OptimizerWrapper::Result.get(id)
            status 202
            if solution && !solution.empty?
              output_format = params[:format]&.to_sym || (solution['csv'] ? :csv : env['api.format'])
              if output_format == :csv
                present(OptimizerWrapper.build_csv(solution['result']), type: CSV)
              else
                present({
                  solutions: [solution['result']],
                  job: {
                    id: id,
                    status: :killed,
                    avancement: job.message,
                    graph: solution['graph']
                  }
                }, with: Grape::Presenters::Presenter)
              end
            else
              present({
                job: {
                  id: id,
                  status: :killed,
                }
              }, with: Grape::Presenters::Presenter)
            end
            OptimizerWrapper.job_remove(params[:api_key], id)
          end
        end
      end
    end
  end
end
