module bc_euler_pressureoutlet
    use mod_kinds,          only: rk,ik
    use mod_constants,      only: ONE, TWO, HALF
    use atype_bc,           only: bc_t
    use atype_solverdata,   only: solverdata_t
    use type_mesh,          only: mesh_t
    use type_properties,    only: properties_t
    use mod_DNAD_tools,     only: compute_seed_element
    use mod_integrate,      only: integrate_boundary_scalar_flux
    use mod_interpolate,    only: interpolate
    use DNAD_D
    
    use EULER_properties,   only: EULER_properties_t
    implicit none


    !> Extrapolation boundary condition 
    !!      - Extrapolate interior variables to be used for calculating the boundary flux.
    !!  
    !!  @author Nathan A. Wukie
    !!
    !-------------------------------------------------------------------------------------------
    type, public, extends(bc_t) :: euler_pressureoutlet_t

    contains
        procedure :: compute    !> bc implementation
    end type euler_pressureoutlet_t
    !-------------------------------------------------------------------------------------------




contains

    !> Specialized compute routine for Extrapolation Boundary Condition
    !!
    !!  @author Nathan A. Wukie
    !!
    !!  @param[in]      mesh    Mesh data containing elements and faces for the domain
    !!  @param[inout]   sdata   Solver data containing solution vector, rhs, linearization, etc.
    !!  @param[in]      ielem   Index of the element being computed
    !!  @param[in]      iface   Index of the face being computed
    !!  @param[in]      iblk    Index of the linearization block being computed
    !!  @param[inout]   prop    properties_t object containing equations and material_t objects
    !-------------------------------------------------------------------------------------------
    subroutine compute(self,mesh,sdata,ielem,iface,iblk,prop)
        class(euler_pressureoutlet_t),  intent(inout)   :: self
        type(mesh_t),                   intent(in)      :: mesh
        class(solverdata_t),            intent(inout)   :: sdata
        integer(ik),                    intent(in)      :: ielem
        integer(ik),                    intent(in)      :: iface
        integer(ik),                    intent(in)      :: iblk
        class(properties_t),            intent(inout)   :: prop

        ! Equation indices
        integer(ik) :: irho, irhou, irhov, irhow, irhoE

        integer(ik) :: iseed, iface_p, ineighbor

        ! Storage at quadrature nodes
        type(AD_D), dimension(mesh%faces(ielem,iface)%gq%face%nnodes)   ::  &
                        rho_m,  rhou_m, rhov_m, rhow_m, rhoE_m,             &
                        flux_x, flux_y, flux_z, flux,                       &
                        u_m,    v_m,    w_m,                                &
                        H_bc,   rhoE_bc

        real(rk)    :: gam_m

        real(rk),   dimension(mesh%faces(ielem,iface)%gq%face%nnodes)   :: p_bc



        !
        ! Get equation indices
        !
        irho  = prop%get_eqn_index("rho")
        irhou = prop%get_eqn_index("rhou")
        irhov = prop%get_eqn_index("rhov")
        irhow = prop%get_eqn_index("rhow")
        irhoE = prop%get_eqn_index("rhoE")

        !
        ! Get seed element for derivatives
        !
        iseed = compute_seed_element(mesh,ielem,iblk)


        !
        ! Set back pressure
        !
        p_bc = 93000._rk
        !p_bc = 100000._rk
        !p_bc = 2.92205471_rk
        !p_bc = 2.8715_rk



        associate (norms => mesh%faces(ielem,iface)%norm, unorms => mesh%faces(ielem,iface)%unorm, faces => mesh%faces, q => sdata%q)


            !
            ! Interpolate interior solution to quadrature nodes
            !
            call interpolate(faces,q,ielem,iface,irho, rho_m, iseed)
            call interpolate(faces,q,ielem,iface,irhou,rhou_m,iseed)
            call interpolate(faces,q,ielem,iface,irhov,rhov_m,iseed)
            call interpolate(faces,q,ielem,iface,irhow,rhow_m,iseed)
            call interpolate(faces,q,ielem,iface,irhoE,rhoE_m,iseed)


            !
            ! Compute velocity components
            !
            u_m = rhou_m/rho_m
            v_m = rhov_m/rho_m
            w_m = rhow_m/rho_m


            !& HARDCODED GAMMA
            gam_m = 1.4_rk


            !
            ! Compute boundary condition energy and enthalpy
            !
            rhoE_bc = p_bc/(gam_m - ONE) + (rho_m/TWO)*(u_m*u_m + v_m*v_m + w_m*w_m)
            H_bc = (rhoE_bc + p_bc)/rho_m

            !=================================================
            ! Mass flux
            !=================================================
            flux_x = (rho_m * u_m)
            flux_y = (rho_m * v_m)
            flux_z = (rho_m * w_m)
            flux = flux_x*norms(:,1) + flux_y*norms(:,2) + flux_z*norms(:,3)

            call integrate_boundary_scalar_flux(mesh%faces(ielem,iface),sdata,irho,iblk,flux)

            !=================================================
            ! x-momentum flux
            !=================================================
            flux_x = (rho_m * u_m * u_m) + p_bc
            flux_y = (rho_m * u_m * v_m)
            flux_z = (rho_m * u_m * w_m)
            flux = flux_x*norms(:,1) + flux_y*norms(:,2) + flux_z*norms(:,3)

            call integrate_boundary_scalar_flux(mesh%faces(ielem,iface),sdata,irhou,iblk,flux)

            !=================================================
            ! y-momentum flux
            !=================================================
            flux_x = (rho_m * v_m * u_m)
            flux_y = (rho_m * v_m * v_m) + p_bc
            flux_z = (rho_m * v_m * w_m)
            flux = flux_x*norms(:,1) + flux_y*norms(:,2) + flux_z*norms(:,3)

            call integrate_boundary_scalar_flux(mesh%faces(ielem,iface),sdata,irhov,iblk,flux)

            !=================================================
            ! z-momentum flux
            !=================================================
            flux_x = (rho_m * w_m * u_m)
            flux_y = (rho_m * w_m * v_m)
            flux_z = (rho_m * w_m * w_m) + p_bc
            flux = flux_x*norms(:,1) + flux_y*norms(:,2) + flux_z*norms(:,3)

            call integrate_boundary_scalar_flux(mesh%faces(ielem,iface),sdata,irhow,iblk,flux)


            !=================================================
            ! Energy flux
            !=================================================
            flux_x = (rho_m * u_m * H_bc)
            flux_y = (rho_m * v_m * H_bc)
            flux_z = (rho_m * w_m * H_bc)
            flux = flux_x*norms(:,1) + flux_y*norms(:,2) + flux_z*norms(:,3)

            call integrate_boundary_scalar_flux(mesh%faces(ielem,iface),sdata,irhoE,iblk,flux)


        end associate

    end subroutine






end module bc_euler_pressureoutlet