## Copyright (C) 2023 Pantxo Diribarne
##
## This program is free software: you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation, either version 3 of the License, or
## (at your option) any later version.
##
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License
## along with this program.  If not, see <https://www.gnu.org/licenses/>.

## -*- texinfo -*-
## @deftypefn {} {@var{out_struct} =} read_mat73_var (@var{fname})
## @deftypefnx {} {@var{out_struct} =} read_mat73_var (@var{fname}, @var{varname})
## Read variables from a HDF5 files formated according to Matlab's
## v7.3 format and return them as a struct.
##
## If an argument @var{varname} is provided, read only the specified variable,
## otherwise return all datasets at the root of the file.
##
## @seealso{H5D.read}
## @end deftypefn

function rdata = read_mat73 (fname, varnames = "__all__")

  if (! ischar (fname))
    error ("read_mat73: FNAME must be a mat file name")
  elseif (! ischar (varnames) && ! iscellstr (varnames))
    print_usage ();
  endif

  fname = file_in_loadpath (fname);

  persistent s = h5info (fname);

  all_vars = get_available_vars (s);

  if (strcmp (varnames, "__all__"))
    varnames = all_vars;
  else
    if (! iscellstr (varnames))
      varnames = {varnames};
    endif

    for ii = 1:numel (varnames)
      if (! any (strcmp (varnames{ii}, all_vars)))
        error ("read_mat73: can't find variable %s in %s", varnames{ii}, fname)
      endif
    endfor
  endif

  file = H5F.open (fname);

  unwind_protect
    rdata = read_vars (file, varnames, s);
  unwind_protect_cleanup
    H5F.close (file);
  end_unwind_protect
endfunction

function rdata = read_vars (obj_id, varnames, s)

  gnames = {};
  if (isfield (s, "Groups") && ! isempty (s.Groups))
    gnames = {s.Groups.Name};
  endif

  dnames = {};
  if (isfield (s, "Datasets")  && ! isempty (s.Datasets))
    dnames = {s.Datasets.Name};
  endif

  rdata = struct ([varnames(:).'; cell(size (varnames(:).'))]{:});

  for ii = 1:numel (varnames)
    varname = varnames{ii};
    isdset = true;

    idx = strcmp (varname, dnames);
    if (any (idx))
      info = s.Datasets(idx);
    else
      idx = strcmp (varname, gnames);
      info = s.Groups(idx);
      isdset = false;
    endif

    if (isdset)
      dset = H5D.open (obj_id, varname, "H5P_DEFAULT");

      try
        cls = var_class (dset);
        h5cls = info.Datatype.Class;
        rdata.(varname) = read_dataset (dset, h5cls, info);
      catch
        H5D.close (dset);
      end_try_catch
    else
      group = H5G.open (obj_id, varname, "H5P_DEFAULT");

      try
        cls = var_class (group);
        tmp = [];
        rdata.(varname) = reinterpret (tmp, group, cls, info);

      catch
        H5G.close (group);
      end_try_catch
    endif

  endfor

endfunction

function val = read_dataset (dset, h5cls, info)

  tmp = H5D.read (dset, "H5ML_DEFAULT", "H5S_ALL", "H5S_ALL", ...
                        "H5P_DEFAULT");

  if (strcmp (h5cls, "H5T_REFERENCE"))
    refs = tmp;
    tmp = {};
    for jj = 1:numel (refs)
      ref = refs(jj);

      ## FIXME: that won't work if the referenced object is a group
      dset_ref = H5R.dereference (dset, "H5R_OBJECT", refs(jj));

      try
        tmp2 =  H5D.read(dset_ref, "H5ML_DEFAULT", "H5S_ALL", ...
                         "H5S_ALL", "H5P_DEFAULT");
        cls = var_class (dset_ref);

        tmp = [tmp, reinterpret(tmp2, dset_ref, cls, info)];
      catch ee
        H5D.close (dset_ref);
        rethrow (ee)
      end_try_catch

    endfor

    val = reshape (tmp, size (refs));
  else
    cls = var_class (dset);
    val = reinterpret(tmp, dset, cls, info);
  endif
endfunction

function vars = get_available_vars (s)
  vars = {};
  dsets = s.Datasets;
  groups = s.Groups;

  for ii = 1:numel (dsets)
    if (! isempty (dsets(ii).Attributes)
        && any (strcmp ({dsets(ii).Attributes.Name}, "MATLAB_class")))
      vars = [vars dsets(ii).Name];
    endif
  endfor

  for ii = 1:numel (groups)
    if (! isempty (groups(ii).Attributes)
        && any (strcmp ({groups(ii).Attributes.Name}, "MATLAB_class")))
      vars = [vars groups(ii).Name];
    endif
  endfor
endfunction

function cls = var_class (id)

  try
    attr_id = H5A.open (id, "MATLAB_class", "H5P_DEFAULT");
    cls = H5A.read (attr_id);
    H5A.close (attr_id)
  catch
    cls = "";
  end_try_catch

endfunction

function val = reinterpret (val, obj_id, cls, info = [])

  empty = (isfield (info.Attributes, "Name")
           && any (strcmp ({info.Attributes.Name}, "MATLAB_empty")));

  switch cls
    case {"cell", ...
          "int8", "int16", "int32", "int64",...
          "uint8", "uint16", "uint32", "uint64"}

      if (empty)
        val = zeros (val, cls);
      endif

    case {"double", "single"}
      if (isstruct (val) && all (isfield (val, {"real", "imag"})))
        val = complex (val.real, val.imag);
      endif

      if (empty)
        val = zeros (val, cls);
      endif

    case "char"
      val = char (val);

      if (empty)
        val = '';
      endif

    case "logical"

      if (empty)
        val = zeros (val, cls);
      else
        val = logical (val);
      endif

    case "struct"
      if (empty)
        val = struct ();
      else
        attr_id = H5A.open (obj_id, "MATLAB_fields", "H5P_DEFAULT");
        fields = H5A.read (attr_id);
        H5A.close (attr_id)

        tmp = read_vars (obj_id, fields, info);

        ## FIXME: how do we differenciate structs and struct-arrays
        allcell = all (cellfun (@(nm) iscell (tmp.(nm)), fields));

        if (allcell)
          args = {};
          for ii = 1:numel (fields)
            args{end+1} = fields{ii};
            args{end+1} = tmp.(fields{ii});
          endfor

          try
            val = struct (args{:});
          catch
            val = tmp;
          end_try_catch
        endif
      endif

    otherwise
      warning ("read_mat73: unhandled class %s, returning data asis", ...
               cls)
  endswitch
endfunction

%!test
%! v7 = load ('base_types_mat7.mat', 'char_empty');
%! v73 = read_mat73 ('base_types_mat73.mat', 'char_empty');
%! assert (v7.char_empty, v73.char_empty)

%!test
%! v7 = load ('base_types_mat7.mat', 'char_vector');
%! v73 = read_mat73 ('base_types_mat73.mat', 'char_vector');
%! assert (v7.char_vector, v73.char_vector)

%!test
%! v7 = load ('base_types_mat7.mat', 'char_matrix');
%! v73 = read_mat73 ('base_types_mat73.mat', 'char_matrix');
%! assert (v7.char_matrix, v73.char_matrix)

%!test
%! v7 = load ('base_types_mat7.mat', 'empty_int8');
%! v73 = read_mat73 ('base_types_mat73.mat', 'empty_int8');
%! assert (v7.empty_int8, v73.empty_int8)

%!test
%! v7 = load ('base_types_mat7.mat', 'empty_int16');
%! v73 = read_mat73 ('base_types_mat73.mat', 'empty_int16');
%! assert (v7.empty_int16, v73.empty_int16)

%!test
%! v7 = load ('base_types_mat7.mat', 'empty_int32');
%! v73 = read_mat73 ('base_types_mat73.mat', 'empty_int32');
%! assert (v7.empty_int32, v73.empty_int32)

%!test
%! v7 = load ('base_types_mat7.mat', 'empty_int64');
%! v73 = read_mat73 ('base_types_mat73.mat', 'empty_int64');
%! assert (v7.empty_int64, v73.empty_int64)

%!test
%! v7 = load ('base_types_mat7.mat', 'empty_uint8');
%! v73 = read_mat73 ('base_types_mat73.mat', 'empty_uint8');
%! assert (v7.empty_uint8, v73.empty_uint8)

%!test
%! v7 = load ('base_types_mat7.mat', 'empty_uint16');
%! v73 = read_mat73 ('base_types_mat73.mat', 'empty_uint16');
%! assert (v7.empty_uint16, v73.empty_uint16)

%!test
%! v7 = load ('base_types_mat7.mat', 'empty_uint32');
%! v73 = read_mat73 ('base_types_mat73.mat', 'empty_uint32');
%! assert (v7.empty_uint32, v73.empty_uint32)

%!test
%! v7 = load ('base_types_mat7.mat', 'empty_uint64');
%! v73 = read_mat73 ('base_types_mat73.mat', 'empty_uint64');
%! assert (v7.empty_uint64, v73.empty_uint64)

%!test
%! v7 = load ('base_types_mat7.mat', 'empty_single');
%! v73 = read_mat73 ('base_types_mat73.mat', 'empty_single');
%! assert (v7.empty_single, v73.empty_single)

%!test
%! v7 = load ('base_types_mat7.mat', 'empty_double');
%! v73 = read_mat73 ('base_types_mat73.mat', 'empty_double');
%! assert (v7.empty_double, v73.empty_double)

%!test
%! v7 = load ('base_types_mat7.mat', 'empty_logical');
%! v73 = read_mat73 ('base_types_mat73.mat', 'empty_logical');
%! assert (v7.empty_logical, v73.empty_logical)

%!test
%! v7 = load ('base_types_mat7.mat', 'scalar_int8');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_int8');
%! assert (v7.scalar_int8, v73.scalar_int8)

%!test
%! v7 = load ('base_types_mat7.mat', 'scalar_int16');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_int16');
%! assert (v7.scalar_int16, v73.scalar_int16)

%!test
%! v7 = load ('base_types_mat7.mat', 'scalar_int32');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_int32');
%! assert (v7.scalar_int32, v73.scalar_int32)

%!test
%! v7 = load ('base_types_mat7.mat', 'scalar_int64');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_int64');
%! assert (v7.scalar_int64, v73.scalar_int64)

%!test
%! v7 = load ('base_types_mat7.mat', 'scalar_uint8');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_uint8');
%! assert (v7.scalar_uint8, v73.scalar_uint8)

%!test
%! v7 = load ('base_types_mat7.mat', 'scalar_uint16');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_uint16');
%! assert (v7.scalar_uint16, v73.scalar_uint16)

%!test
%! v7 = load ('base_types_mat7.mat', 'scalar_uint32');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_uint32');
%! assert (v7.scalar_uint32, v73.scalar_uint32)

%!test
%! v7 = load ('base_types_mat7.mat', 'scalar_uint64');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_uint64');
%! assert (v7.scalar_uint64, v73.scalar_uint64)

%!test
%! v7 = load ('base_types_mat7.mat', 'scalar_double');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_double');
%! assert (v7.scalar_double, v73.scalar_double)

%!test
%! v7 = load ('base_types_mat7.mat', 'scalar_single');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_single');
%! assert (v7.scalar_single, v73.scalar_single)

%!test
%! v7 = load ('base_types_mat7.mat', 'scalar_logical');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_logical');
%! assert (v7.scalar_logical, v73.scalar_logical)

%!test
%! v7 = load ('base_types_mat7.mat', 'ndim_int8');
%! v73 = read_mat73 ('base_types_mat73.mat', 'ndim_int8');
%! assert (v7.ndim_int8, v73.ndim_int8)

%!test
%! v7 = load ('base_types_mat7.mat', 'ndim_int16');
%! v73 = read_mat73 ('base_types_mat73.mat', 'ndim_int16');
%! assert (v7.ndim_int16, v73.ndim_int16)

%!test
%! v7 = load ('base_types_mat7.mat', 'ndim_int32');
%! v73 = read_mat73 ('base_types_mat73.mat', 'ndim_int32');
%! assert (v7.ndim_int32, v73.ndim_int32)

%!test
%! v7 = load ('base_types_mat7.mat', 'ndim_int64');
%! v73 = read_mat73 ('base_types_mat73.mat', 'ndim_int64');
%! assert (v7.ndim_int64, v73.ndim_int64)

%!test
%! v7 = load ('base_types_mat7.mat', 'ndim_uint8');
%! v73 = read_mat73 ('base_types_mat73.mat', 'ndim_uint8');
%! assert (v7.ndim_uint8, v73.ndim_uint8)

%!test
%! v7 = load ('base_types_mat7.mat', 'ndim_uint16');
%! v73 = read_mat73 ('base_types_mat73.mat', 'ndim_uint16');
%! assert (v7.ndim_uint16, v73.ndim_uint16)

%!test
%! v7 = load ('base_types_mat7.mat', 'ndim_uint32');
%! v73 = read_mat73 ('base_types_mat73.mat', 'ndim_uint32');
%! assert (v7.ndim_uint32, v73.ndim_uint32)

%!test
%! v7 = load ('base_types_mat7.mat', 'ndim_uint64');
%! v73 = read_mat73 ('base_types_mat73.mat', 'ndim_uint64');
%! assert (v7.ndim_uint64, v73.ndim_uint64)

%!test
%! v7 = load ('base_types_mat7.mat', 'ndim_double');
%! v73 = read_mat73 ('base_types_mat73.mat', 'ndim_double');
%! assert (v7.ndim_double, v73.ndim_double)

%!test
%! v7 = load ('base_types_mat7.mat', 'ndim_single');
%! v73 = read_mat73 ('base_types_mat73.mat', 'ndim_single');
%! assert (v7.ndim_single, v73.ndim_single)

%!test
%! v7 = load ('base_types_mat7.mat', 'ndim_logical');
%! v73 = read_mat73 ('base_types_mat73.mat', 'ndim_logical');
%! assert (v7.ndim_logical, v73.ndim_logical)

## Sparse matrices are still unhandled, marking xtest
%!xtest
%! v7 = load ('base_types_mat7.mat', 'sparse_double');
%! v73 = read_mat73 ('base_types_mat73.mat', 'sparse_double');
%! assert (v7.sparse_double, v73.sparse_double)

%!test
%! v7 = load ('base_types_mat7.mat', 'cplx_scalar_double');
%! v73 = read_mat73 ('base_types_mat73.mat', 'cplx_scalar_double');
%! assert (v7.cplx_scalar_double, v73.cplx_scalar_double)

%!test
%! v7 = load ('base_types_mat7.mat', 'cplx_scalar_single');
%! v73 = read_mat73 ('base_types_mat73.mat', 'cplx_scalar_single');
%! assert (v7.cplx_scalar_single, v73.cplx_scalar_single)

%!test
%! v7 = load ('base_types_mat7.mat', 'cplx_ndim_double');
%! v73 = read_mat73 ('base_types_mat73.mat', 'cplx_ndim_double');
%! assert (v7.cplx_ndim_double, v73.cplx_ndim_double)

%!test
%! v7 = load ('base_types_mat7.mat', 'cplx_ndim_single');
%! v73 = read_mat73 ('base_types_mat73.mat', 'cplx_ndim_single');
%! assert (v7.cplx_ndim_single, v73.cplx_ndim_single)

## Cell arrays are still unhandled, marking xtest
%!test
%! v7 = load ('base_types_mat7.mat', 'cell_any');
%! v73 = read_mat73 ('base_types_mat73.mat', 'cell_any');
%! assert (v7.cell_any, v73.cell_any)

%!test
%! v7 = load ('base_types_mat7.mat', 'cell_str');
%! v73 = read_mat73 ('base_types_mat73.mat', 'cell_str');
%! assert (v7.cell_str, v73.cell_str)

## Scalar structs are still unhandled, marking xtest
%!xtest
%! v7 = load ('base_types_mat7.mat', 'scalar_struct');
%! v73 = read_mat73 ('base_types_mat73.mat', 'scalar_struct');
%! assert (v7.scalar_struct, v73.scalar_struct)

%!test
%! v7 = load ('base_types_mat7.mat', 'struct_array');
%! v73 = read_mat73 ('base_types_mat73.mat', 'struct_array');
%! assert (v7.struct_array, v73.struct_array)
