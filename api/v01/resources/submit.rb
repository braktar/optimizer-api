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

require './api/v01/entities/vrp_input'

module Api
  module V01
    class Submit < APIBase
      helpers VrpInput, VrpConfiguration, VrpMisc, VrpMissions, VrpShared, VrpVehicles
      resource :submit do # rubocop:disable Metrics/BlockLength
        desc 'Submit VRP problem', {
          nickname: 'submit_vrp',
          success: VrpResult,
          failure: [
            { code: 400, message: 'Bad Request', model: ::Api::V01::Status }
          ],
          security: [{
            api_key_query_param: []
          }],
          detail: 'Submit vehicle routing problem. If the problem can be quickly solved, the solution is returned in the response. In other case, the response provides a job identifier in a queue: you need to perfom another request to fetch vrp job status and solution.'
        }
        params {
          use(:input)
        }
        post do # rubocop:disable Metrics/BlockLength
          # Api key is not declared as part of the VRP and must be handled carefully and separatly from other parameters
          api_key = params[:api_key]
          checksum = Digest::MD5.hexdigest Marshal.dump(params)
          d_params = declared(params, include_missing: false)
          vrp_params = d_params[:points] ? d_params : d_params[:vrp]
          APIBase.dump_vrp_dir.write([api_key, vrp_params[:name], checksum].compact.join('_'), { vrp: vrp_params }.to_json) if OptimizerWrapper.config[:dump][:vrp]

          APIBase.services(api_key)[:params_limit].merge(OptimizerWrapper.access[api_key][:params_limit] || {}).each{ |key, value|
            next if vrp_params[key].nil? || value.nil? || vrp_params[key].size <= value

            error!({
              status: 'Exceeded params limit',
              message: "Exceeded #{key} limit authorized for your account: #{value}. Please contact support or sales to increase limits."
            }, 400)
          }

          vrp = ::Models::Vrp.create(vrp_params)
          if !vrp.valid? || vrp_params.nil? || vrp_params.keys.empty?
            vrp.errors.add(:empty_file, message: 'JSON file is empty') if vrp_params.nil?
            vrp.errors.add(:empty_vrp, message: 'VRP structure is empty') if vrp_params&.keys&.empty?
            error!({ status: 'Model Validation Error', message: vrp.errors }, 400)
          else
            ret = OptimizerWrapper.wrapper_vrp(api_key, APIBase.services(api_key), vrp, checksum)
            if ret.is_a?(String)
              # present result, with: VrpResult
              status 201
              present({ job: { id: ret, status: :queued }}, with: Grape::Presenters::Presenter)
            elsif ret.is_a?(Hash)
              status 200
              if vrp.restitution_csv
                present(OptimizerWrapper.build_csv(ret.deep_stringify_keys), type: CSV)
              else
                present({ solutions: [ret], job: { status: :completed }}, with: Grape::Presenters::Presenter)
              end
            else
              error!({ status: 'Internal Server Error' }, 500)
            end
          end
        ensure
          ::Models.delete_all
        end
      end
    end
  end
end
